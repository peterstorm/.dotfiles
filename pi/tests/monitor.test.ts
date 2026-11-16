import { describe, expect, it } from "bun:test";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import monitorExtension from "../extensions/monitor/index";
import {
	MONITOR_CUSTOM_TYPE,
	MONITOR_STATUS_CUSTOM_TYPE,
	createMonitorSpec,
	decideSpawn,
	exitCodeLabel,
	formatCompletion,
	formatMissedCompletion,
	formatMonitorList,
	isValidMonitorName,
	parseExitCodeFile,
	parseMonitorJournalData,
	parseMonitorStatusData,
	projectMonitors,
	tailOf,
} from "../extensions/monitor/state";
import { waitFor } from "./helpers/fake-model-server";

type SentMessage = { content: string; deliverAs?: string; triggerTurn?: boolean };
type AppendedEntry = { customType: string; data: unknown };
type ToolLike = { name: string; execute: (id: string, params: unknown) => Promise<{ content: Array<{ type: string; text: string }>; details: unknown }> };
type CommandLike = { name: string; handler: (args: string, ctx: unknown) => Promise<void> };

// Minimal ExtensionAPI double capturing what the monitor extension registers and emits.
const harness = () => {
	const sent: SentMessage[] = [];
	const appended: AppendedEntry[] = [];
	const tools: Record<string, ToolLike> = {};
	const commands: Record<string, CommandLike> = {};
	const statusLabels: Array<string | undefined> = [];
	let sessionStart: ((event: { reason: string }, ctx: ExtensionContext) => void) | undefined;
	let sessionShutdown: (() => void) | undefined;
	const api = {
		registerTool(definition: { name: string }) {
			tools[definition.name] = definition as ToolLike;
		},
		registerCommand(name: string, definition: CommandLike) {
			commands[name] = definition;
		},
		registerEntryRenderer() {},
		on(event: string, handler: (event?: unknown, ctx?: ExtensionContext) => void) {
			if (event === "session_start") sessionStart = handler as typeof sessionStart;
			if (event === "session_shutdown") sessionShutdown = handler as typeof sessionShutdown;
		},
		sendMessage(message: { content: string }, options: { deliverAs?: string; triggerTurn?: boolean }) {
			sent.push({ content: message.content, deliverAs: options.deliverAs, triggerTurn: options.triggerTurn });
		},
		appendEntry(customType: string, data: unknown) {
			appended.push({ customType, data });
		},
	} as unknown as ExtensionAPI;
	monitorExtension(api);
	const monitor = tools["monitor"];
	const cancel = tools["monitor_cancel"];
	const monitorsCommand = commands["monitors"];
	if (!monitor || !cancel || !monitorsCommand || !sessionStart || !sessionShutdown) {
		throw new Error("extension must register monitor + monitor_cancel tools, the monitors command and session handlers");
	}
	const statusCtx = {
		hasUI: true,
		ui: { setStatus: (_key: string, value: string | undefined) => { statusLabels.push(value); } },
	};
	return { sent, appended, monitor, cancel, monitorsCommand, sessionStart, sessionShutdown, statusLabels, statusCtx };
};

const run = async (tool: ToolLike, args: unknown): Promise<string> =>
	(await tool.execute("call", args)).content[0]?.text ?? "";

const startedEntry = (spec: Record<string, unknown>) => ({ type: "custom", customType: MONITOR_CUSTOM_TYPE, data: { kind: "started", spec } });

const journalEntry = (kind: string, extra: Record<string, unknown>) => ({
	type: "custom",
	customType: MONITOR_CUSTOM_TYPE,
	data: { kind, ...extra },
});

const pidGone = async (pid: number, what: string): Promise<void> => {
	await waitFor(() => {
		try {
			process.kill(pid, 0);
			return false;
		} catch {
			return true;
		}
	}, what);
};

const groupKill = (pid: number): void => {
	try {
		process.kill(-pid, "SIGKILL");
	} catch {
		try {
			process.kill(pid, "SIGKILL");
		} catch {
			// gone
		}
	}
};

describe("monitor state", () => {
	const spec = (over: Partial<Record<string, unknown>> = {}) => ({
		id: "m1", name: "ci", command: "echo hi", pid: 123, logPath: "/tmp/a.log", codePath: "/tmp/a.code", startedAt: 100, ...over,
	});

	it("validates monitor names and sidecar codes", () => {
		expect(isValidMonitorName("ci")).toBe(true);
		expect(isValidMonitorName("build-2.test_x")).toBe(true);
		expect(isValidMonitorName("")).toBe(false);
		expect(isValidMonitorName("-lead")).toBe(false);
		expect(isValidMonitorName("has space")).toBe(false);
		expect(isValidMonitorName("x".repeat(65))).toBe(false);
		// The sidecar invariant: integer in [0, 255]; empty is null, never 0.
		expect(parseExitCodeFile("0")).toBe(0);
		expect(parseExitCodeFile("255")).toBe(255);
		expect(parseExitCodeFile("3")).toBe(3);
		expect(parseExitCodeFile("")).toBeNull();
		expect(parseExitCodeFile("  ")).toBeNull();
		expect(parseExitCodeFile("3.5")).toBeNull();
		expect(parseExitCodeFile("256")).toBeNull();
		expect(parseExitCodeFile("-1")).toBeNull();
		expect(parseExitCodeFile("garbage")).toBeNull();
	});

	it("parses journal data totally", () => {
		expect(parseMonitorJournalData({ kind: "started", spec: spec() })?.kind).toBe("started");
		expect(parseMonitorJournalData({ kind: "finished", id: "m1", name: "ci", exitCode: 0, finishedAt: 5 })?.kind).toBe("finished");
		expect(parseMonitorJournalData({ kind: "finished", id: "m1", name: "ci", exitCode: null, finishedAt: 5 })?.kind).toBe("finished");
		expect(parseMonitorJournalData({ kind: "finished", id: "m1", name: "ci", exitCode: 256, finishedAt: 5 })).toBeUndefined();
		expect(parseMonitorJournalData({ kind: "finished", id: "m1", name: "ci", exitCode: 3.5, finishedAt: 5 })).toBeUndefined();
		expect(parseMonitorJournalData({ kind: "cancelled", id: "m1", name: "ci", cancelledAt: 5 })?.kind).toBe("cancelled");
		expect(parseMonitorJournalData({ kind: "started", spec: { ...spec(), pid: 0 } })).toBeUndefined();
		expect(parseMonitorJournalData({ kind: "started", spec: { ...spec(), name: "bad name" } })).toBeUndefined();
		expect(parseMonitorJournalData({ kind: "other" })).toBeUndefined();
		expect(parseMonitorJournalData("garbage")).toBeUndefined();
		expect(parseMonitorJournalData(null)).toBeUndefined();
	});

	it("parses status payloads and the spec smart constructor gates construction", () => {
		expect(parseMonitorStatusData({ lines: ["a", "b"] })).toEqual(["a", "b"]);
		expect(parseMonitorStatusData({ lines: [] })).toBeUndefined();
		expect(parseMonitorStatusData({ lines: ["a", 5] })).toBeUndefined();
		expect(parseMonitorStatusData("garbage")).toBeUndefined();
		expect(createMonitorSpec(spec())).toBeDefined();
		expect(createMonitorSpec({ ...spec(), pid: 0 })).toBeUndefined();
	});

	it("decides spawn refusals as data", () => {
		expect(decideSpawn([], "ci", "echo hi")).toEqual({ kind: "accepted" });
		expect(decideSpawn([], "bad name", "echo hi")).toEqual({ kind: "refused", reason: "invalid-name" });
		expect(decideSpawn([], "ci", "   ")).toEqual({ kind: "refused", reason: "empty-command" });
		expect(decideSpawn([spec() as unknown as Parameters<typeof decideSpawn>[0][number]], "ci", "echo hi")).toEqual({ kind: "refused", reason: "duplicate-name" });
		const eight = Array.from({ length: 8 }, (_, i) => spec({ id: `m${i}`, name: `n${i}` }) as unknown as Parameters<typeof decideSpawn>[0][number]);
		expect(decideSpawn(eight, "extra", "echo hi")).toEqual({ kind: "refused", reason: "cap-reached" });
	});

	it("projects newest entry per id and skips malformed ones", () => {
		const projection = projectMonitors([
			startedEntry(spec()),
			journalEntry("finished", { id: "m1", name: "ci", exitCode: 1, finishedAt: 200 }),
			startedEntry(spec({ id: "m2", name: "build", pid: 5 })),
			{ type: "custom", customType: MONITOR_CUSTOM_TYPE, data: "garbage" },
			{ type: "message" },
		]);
		expect(projection.get("m1")).toEqual({ kind: "finished", name: "ci", exitCode: 1 });
		expect(projection.get("m2")?.kind).toBe("running");
		expect(projectMonitors([]).size).toBe(0);
	});

	it("extracts a line-boundary tail", () => {
		expect(tailOf("short")).toBe("short");
		const long = Array.from({ length: 400 }, (_, i) => `line-${i}`).join("\n");
		const tail = tailOf(long, 1000);
		expect(tail.length).toBeLessThanOrEqual(1001);
		expect(tail.startsWith("line-")).toBe(true);
		expect(tail.endsWith("line-399")).toBe(true);
	});

	it("formats completions and the /monitors list", () => {
		expect(formatCompletion("ci", 0, "all green")).toContain("Monitor 'ci' finished (exit 0)");
		expect(formatCompletion("ci", null, "", "spawn failed: boom")).toContain("(spawn failed: boom)");
		expect(formatCompletion("ci", null, "")).toContain("terminated");
		expect(formatMissedCompletion("ci", 3, "out")).toContain("ended while pi was not watching");
		expect(exitCodeLabel(null)).toBe("terminated");

		const projection = projectMonitors([
			startedEntry(spec({ id: "a", name: "old", startedAt: 50_000 })),
			startedEntry(spec({ id: "b", name: "new", pid: 7, startedAt: 80_000 })),
			journalEntry("finished", { id: "c", name: "done", exitCode: 0, finishedAt: 90_000 }),
			journalEntry("cancelled", { id: "d", name: "dropped", cancelledAt: 95_000 }),
		]);
		const lines = formatMonitorList(projection, 140_000);
		expect(lines).toEqual([
			"● old — running (pid 123, ~2m)",
			"● new — running (pid 7, ~1m)",
			"✓ done — exit 0",
			"✗ dropped — cancelled",
		]);
	});
});

describe("monitor extension", () => {
	it("starts a command, returns immediately, and completes with the exit code and tail", async () => {
		const h = harness();
		const dir = mkdtempSync(join(tmpdir(), "monitor-unit-"));
		try {
			const result = await run(h.monitor, { name: "ci", command: "echo phase-one; sleep 0.2; echo phase-two" });
			expect(result).toContain("Monitor 'ci' started (pid ");
			expect(h.appended.some((e) => e.customType === MONITOR_CUSTOM_TYPE && (e.data as { kind?: string }).kind === "started")).toBe(true);

			await waitFor(() => h.appended.some((e) => (e.data as { kind?: string }).kind === "finished"), "completion", 5_000);
			const finished = h.appended.find((e) => (e.data as { kind?: string }).kind === "finished");
			expect((finished?.data as { exitCode?: number }).exitCode).toBe(0);
			expect(h.sent).toHaveLength(1);
			expect(h.sent[0].content).toContain("Monitor 'ci' finished (exit 0)");
			expect(h.sent[0].content).toContain("phase-two");
			expect(h.sent[0].deliverAs).toBe("steer");
			expect(h.sent[0].triggerTurn).toBe(true);

			// The log and code sidecars are cleaned up after completion.
			const started = h.appended.find((e) => (e.data as { kind?: string }).kind === "started");
			const startedSpec = (started?.data as { spec?: { logPath?: string; codePath?: string } }).spec;
			expect(startedSpec?.logPath && existsSync(startedSpec.logPath)).toBe(false);
			expect(startedSpec?.codePath && existsSync(startedSpec.codePath)).toBe(false);
		} finally {
			h.sessionShutdown();
			rmSync(dir, { recursive: true, force: true });
		}
	});

	it("reports a non-zero exit code", async () => {
		const h = harness();
		try {
			await run(h.monitor, { name: "fail", command: "echo before; exit 3" });
			await waitFor(() => h.appended.some((e) => (e.data as { kind?: string }).kind === "finished"), "completion", 5_000);
			expect((h.appended.find((e) => (e.data as { kind?: string }).kind === "finished")?.data as { exitCode?: number }).exitCode).toBe(3);
			expect(h.sent[0].content).toContain("exit 3");
			expect(h.sent[0].content).toContain("before");
		} finally {
			h.sessionShutdown();
		}
	});

	it("reports a missing sidecar as terminated with no output section", async () => {
		const h = harness();
		const dir = mkdtempSync(join(tmpdir(), "monitor-nosidecar-"));
		try {
			// Adoption of a monitor whose wrapper died before writing its sidecars:
			// the exit code is genuinely lost and must read as terminated, never as a
			// fabricated code, and the empty tail must omit the output section.
			const child = spawn("sleep", ["0.05"]);
			await new Promise<void>((resolve) => child.on("exit", resolve));
			h.sessionStart({ reason: "resume" }, {
				sessionManager: { getEntries: () => [startedEntry({
					id: "nosidecar", name: "ghost", command: "echo hi", pid: child.pid,
					logPath: join(dir, "absent.log"), codePath: join(dir, "absent.code"), startedAt: Date.now() - 10_000,
				})] },
			} as unknown as ExtensionContext);
			await waitFor(() => h.appended.some((e) => (e.data as { kind?: string }).kind === "finished"), "completion", 5_000);
			expect((h.appended.find((e) => (e.data as { kind?: string }).kind === "finished")?.data as { exitCode?: number | null }).exitCode).toBeNull();
			expect(h.sent[0].content).toContain("ended while pi was not watching");
			expect(h.sent[0].content).toContain("terminated");
			expect(h.sent[0].content).not.toContain("Last output");
		} finally {
			h.sessionShutdown();
			rmSync(dir, { recursive: true, force: true });
		}
	});

	it("bounds the delivered completion to the 4 KB tail", async () => {
		const h = harness();
		try {
			await run(h.monitor, { name: "noisy", command: "seq 1 2000" });
			await waitFor(() => h.sent.length === 1, "completion", 5_000);
			const message = h.sent[0].content;
			const tail = message.slice(message.indexOf("Last output:"));
			expect(tail.length).toBeLessThan(4_400);
			expect(message).toContain("Monitor 'noisy' finished (exit 0)");
			// The tail starts at a line boundary: the first retained line is complete.
			expect(tail.startsWith("Last output:\n")).toBe(true);
			expect(tail).toContain("\n2000");
		} finally {
			h.sessionShutdown();
		}
	});

	it("dispatches concurrent monitors by id with their own completions", async () => {
		const h = harness();
		const pids: number[] = [];
		try {
			const first = await run(h.monitor, { name: "one", command: "echo alpha-output; exit 0" });
			const second = await run(h.monitor, { name: "two", command: "echo beta-output; exit 5" });
			pids.push(Number(first.match(/pid (\d+)/)?.[1]), Number(second.match(/pid (\d+)/)?.[1]));
			await waitFor(() => h.sent.length === 2, "both completions", 5_000);
			const messages = h.sent.map((m) => m.content);
			expect(messages.some((m) => m.includes("Monitor 'one' finished (exit 0)") && m.includes("alpha-output"))).toBe(true);
			expect(messages.some((m) => m.includes("Monitor 'two' finished (exit 5)") && m.includes("beta-output"))).toBe(true);
		} finally {
			h.sessionShutdown();
			for (const pid of pids) groupKill(pid);
		}
	});

	it("shows and clears the footer status when a UI is present", async () => {
		const h = harness();
		const dir = mkdtempSync(join(tmpdir(), "monitor-status-"));
		try {
			h.sessionStart({ reason: "startup" }, { ...h.statusCtx, sessionManager: { getEntries: () => [] } } as unknown as ExtensionContext);
			await run(h.monitor, { name: "ft", command: "sleep 0.2; echo done" });
			expect(h.statusLabels.at(-1)).toBe("1 running: ft");
			await waitFor(() => h.appended.some((e) => (e.data as { kind?: string }).kind === "finished"), "completion", 5_000);
			expect(h.statusLabels.at(-1)).toBeUndefined();
			void dir;
		} finally {
			h.sessionShutdown();
			// Shutdown clears the label as its last status write.
			expect(h.statusLabels.at(-1)).toBeUndefined();
			rmSync(dir, { recursive: true, force: true });
		}
	});

	it("lists monitors through the /monitors command and cancels through it", async () => {
		const h = harness();
		try {
			const result = await run(h.monitor, { name: "listed", command: "sleep 30" });
			const pid = Number(result.match(/pid (\d+)/)?.[1]);
			await h.monitorsCommand.handler("", { sessionManager: { getEntries: () => h.appended.map((e) => ({ type: e.customType === MONITOR_CUSTOM_TYPE ? "custom" : "custom", customType: e.customType, data: e.data })) } });
			const statusEntry = h.appended.find((e) => e.customType === MONITOR_STATUS_CUSTOM_TYPE);
			const lines = parseMonitorStatusData(statusEntry?.data) ?? [];
			expect(lines.some((line) => line.includes("● listed — running"))).toBe(true);

			await h.monitorsCommand.handler("cancel listed", {});
			expect(h.appended.some((e) => (e.data as { kind?: string }).kind === "cancelled")).toBe(true);
			await pidGone(pid, "wrapper pid to die after command cancel");
			expect(h.sent).toHaveLength(0);
		} finally {
			h.sessionShutdown();
		}
	});

	it("cancels a running monitor: cancelled entry, dead wrapper, no completion", async () => {
		const h = harness();
		try {
			const result = await run(h.monitor, { name: "slow", command: "sleep 30" });
			const pid = Number(result.match(/pid (\d+)/)?.[1]);
			expect(pid).toBeGreaterThan(0);

			const cancelResult = await run(h.cancel, { name: "slow" });
			expect(cancelResult).toContain("cancelled");
			expect(h.appended.some((e) => (e.data as { kind?: string }).kind === "cancelled")).toBe(true);
			await pidGone(pid, "wrapper pid to die");
			expect(h.sent).toHaveLength(0);
			expect(h.appended.some((e) => (e.data as { kind?: string }).kind === "finished")).toBe(false);
			expect(await run(h.cancel, { name: "slow" })).toContain("No active monitor");
		} finally {
			h.sessionShutdown();
		}
	});

	it("rejects duplicate names, invalid names, and exceeding the cap", async () => {
		const h = harness();
		const pids: number[] = [];
		try {
			expect(await run(h.monitor, { name: "bad name", command: "echo x" })).toContain("not a valid monitor name");
			expect(await run(h.monitor, { name: "ok", command: "   " })).toContain("empty");

			for (let i = 0; i < 8; i++) {
				const result = await run(h.monitor, { name: `m${i}`, command: "sleep 30" });
				pids.push(Number(result.match(/pid (\d+)/)?.[1]));
			}
			expect(await run(h.monitor, { name: "extra", command: "sleep 30" })).toContain("cap (8) is reached");
			expect(await run(h.monitor, { name: "m3", command: "echo x" })).toContain("already running");
		} finally {
			h.sessionShutdown();
			for (const pid of pids) groupKill(pid);
		}
	});

	it("adopts a live monitor from the journal and cancels it by name", async () => {
		const h = harness();
		// A previously-spawned wrapper: detached, with the monitor's argv marker.
		const sleeper = spawn("bash", ["-c", '( eval "sleep 30" ); exit 0', "pi-monitor-adopt"], { detached: true, stdio: "ignore" });
		try {
			h.sessionStart({ reason: "reload" }, {
				sessionManager: { getEntries: () => [startedEntry({
					id: "adopt", name: "adopted", command: "sleep 30", pid: sleeper.pid, logPath: "/tmp/none.log", codePath: "/tmp/none.code", startedAt: Date.now(),
				})] },
			} as unknown as ExtensionContext);
			expect(h.sent).toHaveLength(0);
			expect(h.appended).toHaveLength(0);
			const cancelResult = await run(h.cancel, { name: "adopted" });
			expect(cancelResult).toContain("cancelled");
			await pidGone(sleeper.pid ?? 0, "adopted wrapper to die");
		} finally {
			h.sessionShutdown();
		}
	});

	it("completes a monitor that ended while pi was away (dead pid at adoption)", async () => {
		const h = harness();
		const dir = mkdtempSync(join(tmpdir(), "monitor-missed-"));
		try {
			const child = spawn("sleep", ["0.05"]);
			await new Promise<void>((resolve) => child.on("exit", resolve));
			const logPath = join(dir, "gone.log");
			const codePath = join(dir, "gone.code");
			writeFileSync(logPath, "line-one\nline-two\n");
			writeFileSync(codePath, "7");
			h.sessionStart({ reason: "resume" }, {
				sessionManager: { getEntries: () => [startedEntry({
					id: "gone", name: "gone", command: "echo hi", pid: child.pid, logPath, codePath, startedAt: Date.now() - 10_000,
				})] },
			} as unknown as ExtensionContext);
			expect(h.sent).toHaveLength(1);
			expect(h.sent[0].content).toContain("Monitor 'gone' ended while pi was not watching");
			expect(h.sent[0].content).toContain("line-two");
			const finished = h.appended.find((e) => (e.data as { kind?: string }).kind === "finished");
			expect((finished?.data as { exitCode?: number }).exitCode).toBe(7);
		} finally {
			h.sessionShutdown();
			rmSync(dir, { recursive: true, force: true });
		}
	});

	it("adoption is idempotent across repeated session_start events", async () => {
		const h = harness();
		const sleeper = spawn("bash", ["-c", '( eval "sleep 30" ); exit 0', "pi-monitor-adopt2"], { detached: true, stdio: "ignore" });
		const entries = () => [startedEntry({
			id: "adopt2", name: "twice", command: "sleep 30", pid: sleeper.pid, logPath: "/tmp/none2.log", codePath: "/tmp/none2.code", startedAt: Date.now(),
		})];
		try {
			const ctx = { sessionManager: { getEntries: entries } } as unknown as ExtensionContext;
			h.sessionStart({ reason: "startup" }, ctx);
			h.sessionStart({ reason: "startup" }, ctx);
			expect(h.appended).toHaveLength(0);
			await run(h.cancel, { name: "twice" });
			expect(h.appended.filter((e) => (e.data as { kind?: string }).kind === "cancelled")).toHaveLength(1);
		} finally {
			h.sessionShutdown();
		}
	});

	it("shutdown is idempotent and clears adoption state", () => {
		const h = harness();
		h.sessionStart({ reason: "startup" }, { sessionManager: { getEntries: () => [] } } as unknown as ExtensionContext);
		h.sessionShutdown();
		h.sessionShutdown(); // idempotent
		expect(h.appended).toHaveLength(0);
		expect(h.sent).toHaveLength(0);
	});
});
