/**
 * Pool integration: drives the registered `subagent` tool through a fake Pi host and a fake child
 * process (the same execPath substitution the execution suite uses), so the parts that only exist in
 * the wiring are exercised for real — parameter parsing, governance refusal, dispatch through the
 * process-wide pool, result ordering, retries, background messages, and process-group cancellation.
 *
 * `bun test pi/extensions/subagent/pool.integration.test.ts` from the installed extension directory.
 */
import { afterEach, describe, expect, it } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import subagentExtension, { type SubagentDetails } from "./index";

const scratch: string[] = [];

afterEach(() => {
	for (const dir of scratch.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const ROUTING_POLICY = {
	schemaVersion: 1,
	defaultClass: "cloud",
	modelClasses: { local: ["desktop-vllm/*"] },
	targets: {},
	rules: [{ id: "local", when: { parentClass: "local" }, use: { kind: "parent" } }],
};

const AGENT_MARKDOWN = "---\nname: fixture\ndescription: pool fixture agent\n---\nDo the task.\n";

/** Fake child: sleeps per `sleep=NN` in the task, can fail once (`flaky`), or hang (`hang`). */
const FAKE_PI_SOURCE = `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const args = process.argv.slice(2);
const log = (record) => fs.appendFileSync(process.env.FAKE_PI_LOG, JSON.stringify(record) + "\\n");
log({ kind: "spawn", pid: process.pid, at: Date.now() });
const task = args[args.length - 1] || "";
const sleepMatch = /sleep=(\\d+)/.exec(task);
const sleepMs = sleepMatch ? Number(sleepMatch[1]) : 10;
if (task.includes("hang")) {
  const grandchild = spawn(process.execPath, ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], { stdio: "ignore" });
  log({ kind: "grandchild", pid: grandchild.pid });
  process.on("SIGTERM", () => log({ kind: "sigterm", pid: process.pid }));
  setInterval(() => {}, 1000);
} else if (task.includes("flaky")) {
  const marker = path.join(process.env.FAKE_STATE_DIR, "flaky-count");
  const count = fs.existsSync(marker) ? Number(fs.readFileSync(marker, "utf8")) : 0;
  fs.writeFileSync(marker, String(count + 1));
  if (count === 0) {
    log({ kind: "fail", pid: process.pid, at: Date.now() });
    process.stderr.write("transient failure\\n");
    process.exit(7);
  }
  finish();
} else {
  finish();
}
function finish() {
  setTimeout(() => {
    process.stdout.write(JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "done:" + task }], model: "deepseek-v4-flash" } }) + "\\n");
    log({ kind: "end", pid: process.pid, at: Date.now() });
    process.exit(0);
  }, sleepMs);
}
`;

type Fixture = Readonly<{
	root: string;
	agentDir: string;
	projectDir: string;
	logPath: string;
	stateDir: string;
	child: string;
	env: Readonly<Record<string, string>>;
}>;

function createFixture(): Fixture {
	const root = mkdtempSync(join(tmpdir(), "subagent-pool-"));
	scratch.push(root);
	const agentDir = join(root, "agent");
	const projectDir = join(root, "project");
	const stateDir = join(root, "state");
	mkdirSync(join(agentDir, "agents"), { recursive: true });
	mkdirSync(join(projectDir, ".pi", "agents"), { recursive: true });
	mkdirSync(stateDir, { recursive: true });
	writeFileSync(join(agentDir, "model-routing.json"), JSON.stringify(ROUTING_POLICY));
	writeFileSync(join(projectDir, ".pi", "agents", "fixture.md"), AGENT_MARKDOWN);
	const child = join(root, "fake-pi");
	writeFileSync(child, FAKE_PI_SOURCE);
	chmodSync(child, 0o755);
	return {
		root,
		agentDir,
		projectDir,
		logPath: join(root, "child.log"),
		stateDir,
		child,
		env: { PI_CODING_AGENT_DIR: agentDir, FAKE_PI_LOG: join(root, "child.log"), FAKE_STATE_DIR: stateDir },
	};
}

const MANAGED_ENV = ["PI_CODING_AGENT_DIR", "FAKE_PI_LOG", "FAKE_STATE_DIR", "PI_SUBAGENT_POOL_CONCURRENCY"] as const;

async function withFixture<T>(
	overrides: Readonly<Record<string, string>>,
	run: (fixture: Fixture) => Promise<T>,
): Promise<T> {
	const fixture = createFixture();
	const previous = new Map<string, string | undefined>();
	for (const key of MANAGED_ENV) previous.set(key, process.env[key]);
	const previousExecPath = process.execPath;
	Object.defineProperty(process, "execPath", { value: fixture.child, configurable: true });
	for (const [key, value] of Object.entries({ ...fixture.env, ...overrides })) process.env[key] = value;
	try {
		return await run(fixture);
	} finally {
		Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		for (const [key, value] of previous) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	}
}

type ToolExecute = (
	toolCallId: string,
	params: Record<string, unknown>,
	signal: AbortSignal | undefined,
	onUpdate: ((partial: AgentToolResult<SubagentDetails>) => void) | undefined,
	ctx: Record<string, unknown>,
) => Promise<AgentToolResult<SubagentDetails>>;

type Host = Readonly<{
	execute: ToolExecute;
	messages: string[];
}>;

function host(): Host {
	let execute: ToolExecute | undefined;
	const messages: string[] = [];
	const pi = {
		events: { emit: () => {}, on: () => () => {} },
		registerTool: (tool: { execute: unknown }) => {
			execute = tool.execute as unknown as ToolExecute;
		},
		registerCommand: () => {},
		sendMessage: (message: { content?: unknown }) => {
			if (typeof message.content === "string") messages.push(message.content);
		},
		on: () => {},
		appendEntry: () => {},
	} as unknown as ExtensionAPI;
	subagentExtension(pi);
	if (execute === undefined) throw new Error("subagent tool was not registered");
	return { execute, messages };
}

function context(projectDir: string): Record<string, unknown> {
	return {
		cwd: projectDir,
		hasUI: false,
		model: { provider: "desktop-vllm", id: "deepseek-v4-flash" },
		thinkingLevel: "low",
		modelRegistry: { getAll: () => [], find: () => undefined, getApiKeyForProvider: async () => undefined },
		sessionManager: { getSessionId: () => "session-pool-test" },
	};
}

type ChildRecord = Readonly<{ kind: string; pid?: number; at?: number }>;

function readLog(logPath: string): ChildRecord[] {
	if (!existsSync(logPath)) return [];
	return readFileSync(logPath, "utf8")
		.trim()
		.split("\n")
		.filter((line) => line.length > 0)
		.map((line): ChildRecord => JSON.parse(line) as ChildRecord);
}

function maxConcurrent(records: readonly ChildRecord[]): number {
	const events = records.flatMap((record) => {
		const at = typeof record.at === "number" ? record.at : 0;
		if (record.kind === "spawn") return [{ at, delta: 1 }];
		if (record.kind === "end") return [{ at, delta: -1 }];
		return [];
	});
	// Ends sort before starts on the same millisecond: the conservative reading.
	events.sort((left, right) => left.at - right.at || left.delta - right.delta);
	let live = 0;
	let highest = 0;
	for (const event of events) {
		live += event.delta;
		highest = Math.max(highest, live);
	}
	return highest;
}

function taskParams(tasks: string[], pool: unknown, extra: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		tasks: tasks.map((task) => ({ agent: "fixture", task })),
		agentScope: "project",
		pool,
		...extra,
	};
}

async function waitFor(predicate: () => boolean, timeoutMs = 8_000): Promise<void> {
	const startedAt = Date.now();
	while (!predicate()) {
		if (Date.now() - startedAt >= timeoutMs) throw new Error(`condition timed out after ${timeoutMs}ms`);
		await Bun.sleep(10);
	}
}

function isAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

describe("subagent pool", () => {
	it("drains a blocking batch in input order without exceeding the configured cap", async () => {
		await withFixture({ PI_SUBAGENT_POOL_CONCURRENCY: "2" }, async (fixture) => {
			const { execute } = host();
			const tasks = ["t0 sleep=60", "t1 sleep=60", "t2 sleep=60", "t3 sleep=60", "t4 sleep=60"];
			const result = await execute("call-cap", taskParams(tasks, true), undefined, undefined, context(fixture.projectDir));

			expect(result.isError).toBeFalsy();
			expect(result.details?.results.map((task) => task.task)).toEqual(tasks);
			expect(result.details?.results.map((task) => task.exitCode)).toEqual([0, 0, 0, 0, 0]);
			expect(result.content[0]).toMatchObject({ type: "text" });
			expect(maxConcurrent(readLog(fixture.logPath))).toBeLessThanOrEqual(2);
		});
	});

	it("refuses an invalid maxAttempts before spawning", async () => {
		await withFixture({}, async (fixture) => {
			const { execute } = host();
			const result = await execute(
				"call-invalid",
				taskParams(["t0"], { maxAttempts: 4 }),
				undefined,
				undefined,
				context(fixture.projectDir),
			);
			expect(result.isError).toBe(true);
			expect(readLog(fixture.logPath)).toEqual([]);
		});
	});

	it("refuses a chain and an over-cap batch", async () => {
		await withFixture({}, async (fixture) => {
			const { execute } = host();
			const chain = await execute(
				"call-chain",
				{ chain: [{ agent: "fixture", task: "first" }], agentScope: "project", pool: true },
				undefined,
				undefined,
				context(fixture.projectDir),
			);
			expect(chain.isError).toBe(true);

			const tooMany = await execute(
				"call-many",
				taskParams(Array.from({ length: 65 }, (_unused, index) => `t${index}`), true),
				undefined,
				undefined,
				context(fixture.projectDir),
			);
			expect(tooMany.isError).toBe(true);
			expect(readLog(fixture.logPath)).toEqual([]);
		});
	});

	it("refuses background mode for Loom-governed tasks and spawns nothing", async () => {
		await withFixture({}, async (fixture) => {
			const { execute } = host();
			const result = await execute(
				"call-governed",
				taskParams(["binding\nTask ID: wave-1/impl-2\nLOOM_TASK_ID=x"], { background: true }),
				undefined,
				undefined,
				context(fixture.projectDir),
			);
			expect(result.isError).toBe(true);
			expect(result.content[0]).toMatchObject({ type: "text" });
			expect(readLog(fixture.logPath)).toEqual([]);
		});
	});

	it("returns immediately in background mode and reports completion as a message", async () => {
		await withFixture({}, async (fixture) => {
			const { execute, messages } = host();
			const startedAt = Date.now();
			const result = await execute(
				"call-background",
				taskParams(["bg0 sleep=40", "bg1 sleep=40"], { background: true }),
				undefined,
				undefined,
				context(fixture.projectDir),
			);
			const elapsed = Date.now() - startedAt;
			expect(elapsed).toBeLessThan(2_000);
			expect(result.isError).toBeFalsy();
			expect(result.details?.pool).toMatchObject({ cap: 8 });
			expect(result.details?.results).toEqual([]);

			await waitFor(() => messages.some((message) => message.includes("Subagent pool drained")));
			const drained = messages.join("\n\n");
			expect(drained).toContain("bg0 sleep=40");
			expect(drained).toContain("bg1 sleep=40");
		});
	});

	it("retries a process-level failure once and returns the successful attempt", async () => {
		await withFixture({}, async (fixture) => {
			const { execute } = host();
			const result = await execute(
				"call-retry",
				taskParams(["flaky sleep=5"], { maxAttempts: 2 }),
				undefined,
				undefined,
				context(fixture.projectDir),
			);
			const [task] = result.details?.results ?? [];
			expect(task?.exitCode).toBe(0);
			const spawns = readLog(fixture.logPath).filter((record) => record.kind === "spawn");
			const failures = readLog(fixture.logPath).filter((record) => record.kind === "fail");
			expect(spawns).toHaveLength(2);
			expect(failures).toHaveLength(1);
		});
	});

	it("kills the whole process group on abort, including a SIGTERM-ignoring grandchild", async () => {
		await withFixture({}, async (fixture) => {
			const { execute } = host();
			const controller = new AbortController();
			const pending = execute(
				"call-hang",
				taskParams(["hang"], true),
				controller.signal,
				undefined,
				context(fixture.projectDir),
			);

			await waitFor(() => readLog(fixture.logPath).some((record) => record.kind === "grandchild"));
			const grandchild = readLog(fixture.logPath).find((record) => record.kind === "grandchild");
			controller.abort();
			const result = await pending;

			const [task] = result.details?.results ?? [];
			expect(result.isError).toBe(true);
			expect(task?.stopReason).toBe("aborted");
			expect(readLog(fixture.logPath).some((record) => record.kind === "sigterm")).toBe(true);
			const grandchildPid = grandchild?.pid;
			if (typeof grandchildPid !== "number") throw new Error("fixture did not record the grandchild pid");
			await waitFor(() => !isAlive(grandchildPid));
		});
	}, 20_000);
});
