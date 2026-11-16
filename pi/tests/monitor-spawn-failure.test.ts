// Shell-level pin for the spawn-failure arm (monitor-successor-20261116:
// silent-failure-hunter-9 / pr-test-analyzer-7): the child 'error' listener is
// attached before anything can return, an asynchronously reported spawn failure
// routes into completeMonitorWithError, and the completion carries the cause.
// The node:child_process mock is a pass-through — only a command carrying the
// sentinel env gets the fake child — so sharing bun's module cache across test
// files cannot change the behavior of real spawns elsewhere in the suite.
import { describe, expect, it, mock } from "bun:test";
import { EventEmitter } from "node:events";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { waitFor } from "./helpers/fake-model-server";

type FakeChild = EventEmitter & { pid: number | undefined; unref: () => void };
type SentMessage = { content: string };
type AppendedEntry = { customType: string; data: unknown };
type ToolLike = { name: string; execute: (id: string, params: unknown) => Promise<{ content: Array<{ type: string; text: string }>; details: unknown }> };

const SENTINEL = "pi-monitor-spawn-failure-sentinel";
const fakes: FakeChild[] = [];
let nextPid: number | undefined;

const makeFake = (): FakeChild => {
	const child = new EventEmitter() as FakeChild;
	child.pid = nextPid;
	child.unref = () => {};
	fakes.push(child);
	return child;
};

const realCp = await import("node:child_process");
// Capture the raw function BEFORE mock.module: bun patches the module namespace in
// place, so a `realCp.spawn` lookup inside the mock would re-enter the mock.
const realSpawn = realCp.spawn;
const passthrough = { ...realCp, spawn: realSpawn };
mock.module("node:child_process", () => ({
	...passthrough,
	spawn: (
		cmd: Parameters<typeof realSpawn>[0],
		args: Parameters<typeof realSpawn>[1],
		opts: Parameters<typeof realSpawn>[2],
	) =>
		(opts as { env?: Record<string, string | undefined> } | undefined)?.env?.PI_MONITOR_COMMAND === SENTINEL
			? makeFake()
			: realSpawn(cmd, args, opts),
}));

const { default: monitorExtension } = await import("../extensions/monitor/index");

const harness = () => {
	const sent: SentMessage[] = [];
	const appended: AppendedEntry[] = [];
	const tools: Record<string, ToolLike> = {};
	const api = {
		registerTool(definition: { name: string }) {
			tools[definition.name] = definition as ToolLike;
		},
		registerCommand() {},
		registerEntryRenderer() {},
		on() {},
		sendMessage(message: { content: string }) {
			sent.push({ content: message.content });
		},
		appendEntry(customType: string, data: unknown) {
			appended.push({ customType, data });
		},
	} as unknown as ExtensionAPI;
	monitorExtension(api);
	const monitor = tools["monitor"];
	if (!monitor) throw new Error("extension must register the monitor tool");
	return { sent, appended, monitor };
};

const run = async (tool: ToolLike, args: unknown): Promise<string> =>
	(await tool.execute("call", args)).content[0]?.text ?? "";

describe("monitor spawn failure", () => {
	it("a spawn that never gets a pid refuses without an uncaught error", async () => {
		const h = harness();
		nextPid = undefined;
		const result = await run(h.monitor, { name: "nopid", command: SENTINEL });
		expect(result).toContain("Could not start the monitor");
		expect(result).toContain("the process has no pid");
		expect(h.appended).toHaveLength(0);
		// The 'error' listener was attached before the early return: the async
		// failure is handled (an unhandled 'error' would crash the test process).
		await new Promise((resolve) => setTimeout(resolve, 10));
		fakes[0]?.emit("error", new Error("boom"));
		await new Promise((resolve) => setTimeout(resolve, 10));
		expect(h.sent).toHaveLength(0);
		expect(h.appended).toHaveLength(0);
	});

	it("an asynchronous spawn error completes the monitor with the cause and frees the slot", async () => {
		const h = harness();
		nextPid = 4711;
		const result = await run(h.monitor, { name: "err", command: SENTINEL });
		expect(result).toContain("Monitor 'err' started (pid 4711)");
		expect(h.appended.some((e) => (e.data as { kind?: string }).kind === "started")).toBe(true);

		const child = fakes.at(-1);
		if (!child) throw new Error("the mock spawn did not produce a fake child");
		await new Promise((resolve) => setTimeout(resolve, 10));
		child.emit("error", new Error("boom"));
		await waitFor(() => h.sent.length === 1, "the spawn-failure completion", 5_000);
		expect(h.sent[0].content).toContain("Monitor 'err' finished");
		expect(h.sent[0].content).toContain("(spawn failed: boom)");
		const finished = h.appended.find((e) => (e.data as { kind?: string }).kind === "finished");
		expect((finished?.data as { exitCode?: number | null }).exitCode).toBeNull();

		// The cap slot is freed: the same name starts again (through the real spawn —
		// only the sentinel command diverts to the fake).
		nextPid = 4712;
		const again = await run(h.monitor, { name: "err", command: "echo fine" });
		expect(again).toContain("Monitor 'err' started (pid ");
	});
});
