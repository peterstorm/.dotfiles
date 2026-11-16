import { describe, expect, it } from "bun:test";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import monitorExtension from "../extensions/monitor/index";
import {
	MONITOR_CUSTOM_TYPE,
	exitCodeLabel,
	formatCompletion,
	formatMissedCompletion,
	formatMonitorList,
	isValidMonitorName,
	parseMonitorJournalData,
	projectMonitors,
	tailOf,
} from "../extensions/monitor/state";

type SentMessage = { content: string; deliverAs?: string; triggerTurn?: boolean };
type AppendedEntry = { customType: string; data: unknown };
type ToolLike = { name: string; execute: (id: string, params: unknown) => Promise<{ content: Array<{ type: string; text: string }>; details: unknown }> };

const harness = () => {
	const sent: SentMessage[] = [];
	const appended: AppendedEntry[] = [];
	const tools: Record<string, Tool> = {};
	let sessionStart: ((event: { reason: string }, ctx: ExtensionContext) => void) | undefined;
	let sessionShutdown: (() => void) | undefined;
	const api = {
		registerTool(definition: { name: string }) {
			tools[definition.name] = definition as Tool;
		},
		registerCommand() {},
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
	if (!monitor || !cancel || !sessionStart || !sessionShutdown) {
		throw new Error("extension must register monitor + monitor_cancel tools and session handlers");
	}
	return { sent, appended, tools, monitor, cancel, sessionStart, sessionShutdown };
};

const run = async (tool: ToolLike, args: unknown): Promise<string> =>
	(await tool.execute("call", args)).content[0]?.text ?? "";

const startedEntry = (spec: Record<string, unknown>) => ({ type: "custom", customType: MONITOR_CUSTOM_TYPE, data: { kind: "started", spec } });

const journalEntry = (kind: string, extra: Record<string, unknown>) => ({
	type: "custom",
	customType: MONITOR_CUSTOM_TYPE,
	data: { kind, ...extra },
});

const deadPid = async (): Promise<number> => {
	const child = spawn("sleep", ["0.05"]);
	await new Promise<void>((resolve) => child.on("exit", resolve));
	return child.pid ?? 0;
};

const waitFor = async (predicate: () => boolean, what: string, timeoutMs = 5_000): Promise<void> => {
	const start = Date.now();
	while (!predicate()) {
		if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
};

const pidGone = async (pid: number): Promise<void> => {
	await waitFor(() => {
		try {
			process.kill(pid, 0);
			return false;
		} catch {
			return true;
		}
	}, `pid ${pid} to die`);
};

describe("monitor state", () => {
	const spec = (over: Partial<Record<string, unknown>> = {}) => ({
		id: "m1", name: "ci", command: "echo hi", pid: 123, logPath: "/tmp/a.log", codePath: "/tmp/a.code", startedAt: 100, ...over,
	});

	it("validates monitor names", () => {
		expect(isValidMonitorName("ci")).toBe(true);
		expect(isValidMonitorName("build-2.test_x")).toBe(true);
		expect(isValidMonitorName("")).toBe(false);
		expect(isValidMonitorName("-lead")).toBe(false);
		expect(isValidMonitorName("has space")).toBe(false);
		expect(isValidMonitorName("x".repeat(65))).toBe(false);
	});

	it("parses journal data totally", () => {
		expect(parseMonitorJournalData({ kind: "started", spec: spec() })?.kind).toBe("started");
		expect(parseMonitorJournalData({ kind: "finished", id: "m1", name: "ci", exitCode: 0, finishedAt: 5 })?.kind).toBe("finished");
		expect(parseMonitorJournalData({ kind: "finished", id: "m1", name: "ci", exitCode: null, finishedAt: 5 })?.kind).toBe("finished");
		expect(parseMonitorJournalData({ kind: "finished", id: "m1", name: "ci", exitCode: 256, finishedAt: 5 })).toBeUndefined();
		expect(parseMonitorJournalData({ kind: "cancelled", id: "m1", name: "ci", cancelledAt: 5 })?.kind).toBe("cancelled");
		expect(parseMonitorJournalData({ kind: "started", spec: { ...spec(), pid: 0 } })).toBeUndefined();
		expect(parseMonitorJournalData({ kind: "started", spec: { ...spec(), name: "bad name" } })).toBeUndefined();
		expect(parseMonitorJournalData({ kind: "other" })).toBeUndefined();
		expect(parseMonitorJournalData("garbage")).toBeUndefined();
		expect(parseMonitorJournalData(null)).toBeUndefined();
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

			await waitFor(() => h.appended.some((e) => (e.data as { kind?: string }).kind === "finished"), "completion");
			const finished = h.appended.find((e) => (e.data as { kind?: string }).kind === "finished");
			expect((finished?.data as { exitCode?: number }).exitCode).toBe(0);
			expect(h.sent).toHaveLength(1);
			expect(h.sent[0].content).toContain("Monitor 'ci' finished (exit 0)");
			expect(h.sent[0].content).toContain("phase-two");
			expect(h.sent[0].deliverAs).toBe("steer");
			expect(h.sent[0].triggerTurn).toBe(true);

			// The log and code sidecars are cleaned up after completion.
			const started = h.appended.find((e) => (e.data as { kind?: string }).kind === "started");
			const spec = (started?.data as { spec?: { logPath?: string; codePath?: string } }).spec;
			expect(spec?.logPath && existsSync(spec.logPath)).toBe(false);
			expect(spec?.codePath && existsSync(spec.codePath)).toBe(false);
		} finally {
			h.sessionShutdown();
			rmSync(dir, { recursive: true, force: true });
		}
	});

	it("reports a non-zero exit code", async () => {
		const h = harness();
		try {
			await run(h.monitor, { name: "fail", command: "echo before; exit 3" });
			await waitFor(() => h.appended.some((e) => (e.data as { kind?: string }).kind === "finished"), "completion");
			expect((h.appended.find((e) => (e.data as { kind?: string }).kind === "finished")?.data as { exitCode?: number }).exitCode).toBe(3);
			expect(h.sent[0].content).toContain("exit 3");
			expect(h.sent[0].content).toContain("before");
		} finally {
			h.sessionShutdown();
		}
	});

	it("cancels a running monitor: cancelled entry, dead pid, no completion", async () => {
		const h = harness();
		try {
			const result = await run(h.monitor, { name: "slow", command: "sleep 30" });
			const pid = Number(result.match(/pid (\d+)/)?.[1]);
			expect(pid).toBeGreaterThan(0);

			const cancelResult = await run(h.cancel, { name: "slow" });
			expect(cancelResult).toContain("cancelled");
			expect(h.appended.some((e) => (e.data as { kind?: string }).kind === "cancelled")).toBe(true);
			await pidGone(pid);
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
			for (const pid of pids) {
				try {
					process.kill(pid, "SIGKILL");
				} catch {
					// gone
				}
			}
		}
	});

	it("adopts a live monitor from the journal and cancels it by name", async () => {
		const h = harness();
		const sleeper = spawn("sleep", ["30"]);
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
			await pidGone(sleeper.pid ?? 0);
		} finally {
			h.sessionShutdown();
		}
	});

	it("completes a monitor that ended while pi was away (dead pid at adoption)", async () => {
		const h = harness();
		const dir = mkdtempSync(join(tmpdir(), "monitor-missed-"));
		try {
			const pid = await deadPid();
			const logPath = join(dir, "gone.log");
			const codePath = join(dir, "gone.code");
			writeFileSync(logPath, "line-one\nline-two\n");
			writeFileSync(codePath, "7");
			h.sessionStart({ reason: "resume" }, {
				sessionManager: { getEntries: () => [startedEntry({
					id: "gone", name: "gone", command: "echo hi", pid, logPath, codePath, startedAt: Date.now() - 10_000,
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
		const sleeper = spawn("sleep", ["30"]);
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
