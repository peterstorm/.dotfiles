// Repair regression pin for monitor-review-20261116's two surviving criticals:
//   type-design-analyzer-1 — a live pid without the monitor's argv marker is a
//     recycled pid, not the monitor: adoption must report the monitor as ended
//     while pi was away, never adopt a phantom that stalls a cap slot forever.
//   comment-analyzer-1 — cancel must terminate the monitor's whole process tree
//     (the command runs in a subshell under the wrapper), not only the wrapper.
// Historical RED against the reviewed state: pre-fix, the foreign-pid adoption
// installs a phantom poller (no completion ever fires) and cancel signals only
// the wrapper pid (the subshell survives) — both assertions fail there.
import { describe, expect, it } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import monitorExtension from "../extensions/monitor/index";
import { MONITOR_CUSTOM_TYPE } from "../extensions/monitor/state";
import { waitFor } from "./helpers/fake-model-server";

type AppendedEntry = { customType: string; data: unknown };
type ToolLike = { name: string; execute: (id: string, params: unknown) => Promise<{ content: Array<{ type: string; text: string }>; details: unknown }> };

const harness = () => {
	const sent: Array<{ content: string }> = [];
	const appended: AppendedEntry[] = [];
	const tools: Record<string, ToolLike> = {};
	let sessionStart: ((event: { reason: string }, ctx: ExtensionContext) => void) | undefined;
	let sessionShutdown: (() => void) | undefined;
	const api = {
		registerTool(definition: { name: string }) {
			tools[definition.name] = definition as ToolLike;
		},
		registerCommand() {},
		registerEntryRenderer() {},
		on(event: string, handler: (event?: unknown, ctx?: ExtensionContext) => void) {
			if (event === "session_start") sessionStart = handler as typeof sessionStart;
			if (event === "session_shutdown") sessionShutdown = handler as typeof sessionShutdown;
		},
		sendMessage(message: { content: string }) {
			sent.push({ content: message.content });
		},
		appendEntry(customType: string, data: unknown) {
			appended.push({ customType, data });
		},
	} as unknown as ExtensionAPI;
	monitorExtension(api);
	const monitor = tools["monitor"];
	const cancel = tools["monitor_cancel"];
	if (!monitor || !cancel || !sessionStart || !sessionShutdown) {
		throw new Error("extension must register monitor + monitor_cancel tools and session handlers");
	}
	return { sent, appended, monitor, cancel, sessionStart, sessionShutdown };
};

const run = async (tool: ToolLike, args: unknown): Promise<string> =>
	(await tool.execute("call", args)).content[0]?.text ?? "";

const startedEntry = (spec: Record<string, unknown>) => ({ type: "custom", customType: MONITOR_CUSTOM_TYPE, data: { kind: "started", spec } });

const isAlive = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};

const psLine = (pid: number): string => {
	const probe = spawnSync("ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" });
	return probe.status === 0 ? (probe.stdout ?? "") : "";
};

describe("monitor repair regression (monitor-review-20261116)", () => {
	it("cancel terminates the monitor's whole process tree (comment-analyzer-1)", async () => {
		const h = harness();
		const dir = mkdtempSync(join(tmpdir(), "monitor-regression-tree-"));
		try {
			const subshellPidPath = join(dir, "subshell.pid");
			// $! of the backgrounded sleep is a real descendant process in the monitor's
			// process group ($BASHPID does not exist in macOS's bash 3.2). This is the
			// process the reviewed-state cancel left behind as an orphan.
			const result = await run(h.monitor, { name: "tree", command: `sleep 30 & echo $! > ${subshellPidPath}; wait $!` });
			expect(result).toContain("Monitor 'tree' started (pid ");
			await waitFor(() => existsSync(subshellPidPath), "the command to record its subshell pid", 5_000);
			const subshellPid = Number(readFileSync(subshellPidPath, "utf8").trim());
			expect(subshellPid).toBeGreaterThan(0);
			expect(isAlive(subshellPid)).toBe(true);

			const cancelResult = await run(h.cancel, { name: "tree" });
			expect(cancelResult).toContain("cancelled");
			// The command's own process must die with the wrapper, not survive as an orphan.
			await waitFor(() => !isAlive(subshellPid), "the command's subshell to die with the wrapper", 5_000);
			expect(h.sent).toHaveLength(0);
		} finally {
			h.sessionShutdown();
			rmSync(dir, { recursive: true, force: true });
		}
	});

	it("does not adopt a recycled pid as a phantom (type-design-analyzer-1)", async () => {
		const h = harness();
		const dir = mkdtempSync(join(tmpdir(), "monitor-regression-pid-"));
		const foreign = spawn("sleep", ["30"]);
		try {
			// The monitor ran and ended while pi was away; its pid was then recycled by
			// a live foreign process (bare sleep argv, no monitor marker). The sidecars
			// still hold the true outcome.
			const logPath = join(dir, "recycled.log");
			const codePath = join(dir, "recycled.code");
			writeFileSync(logPath, "the true output\n");
			writeFileSync(codePath, "0");
			h.sessionStart({ reason: "resume" }, {
				sessionManager: { getEntries: () => [startedEntry({
					id: "recycled", name: "recycled", command: "echo done", pid: foreign.pid, logPath, codePath, startedAt: Date.now() - 60_000,
				})] },
			} as unknown as ExtensionContext);
			// A phantom adoption never completes; the repair reports the missed ending.
			await waitFor(() => h.appended.some((e) => (e.data as { kind?: string }).kind === "finished"), "the missed completion", 5_000);
			expect(h.sent[0].content).toContain("Monitor 'recycled' ended while pi was not watching");
			expect(h.sent[0].content).toContain("the true output");
			const finished = h.appended.find((e) => (e.data as { kind?: string }).kind === "finished");
			expect((finished?.data as { exitCode?: number }).exitCode).toBe(0);
		} finally {
			h.sessionShutdown();
			foreign.kill("SIGKILL");
			rmSync(dir, { recursive: true, force: true });
		}
	});

	it("cancel never signals a pid whose holder lost the monitor's marker (type-design-analyzer-1, cancel half)", async () => {
		const h = harness();
		// Detached wrapper-shaped process carrying the monitor's argv marker; the exec
		// replaces the image with a foreign argv0 at the same pid — how a recycled pid
		// presents after the monitor exited. Cancel must refuse to signal it.
		const foreign = spawn("bash", ["-c", "sleep 0.4; exec -a foreign-recycled sleep 30", "pi-monitor-gate"], { detached: true, stdio: "ignore" });
		const pid = foreign.pid ?? 0;
		expect(pid).toBeGreaterThan(0);
		try {
			h.sessionStart({ reason: "reload" }, {
				sessionManager: { getEntries: () => [startedEntry({
					id: "gate", name: "gated", command: "sleep 30", pid, logPath: "/tmp/none-gate.log", codePath: "/tmp/none-gate.code", startedAt: Date.now(),
				})] },
			} as unknown as ExtensionContext);
			expect(h.sent).toHaveLength(0);
			// The same pid now runs a foreign image: the argv marker is gone.
			await waitFor(() => {
				const line = psLine(pid);
				return line.length > 0 && !line.includes("pi-monitor-gate");
			}, "the pid's image to lose the monitor's marker", 5_000);
			const cancelResult = await run(h.cancel, { name: "gated" });
			expect(cancelResult).toContain("cancelled");
			expect(cancelResult).toContain("no longer carries this monitor's identity");
			expect(h.appended.some((e) => (e.data as { kind?: string }).kind === "cancelled")).toBe(true);
			// The identity gate refused to signal: the foreign process is still alive.
			expect(isAlive(pid)).toBe(true);
		} finally {
			h.sessionShutdown();
			try {
				process.kill(pid, "SIGKILL");
			} catch {
				// already gone
			}
		}
	});
});
