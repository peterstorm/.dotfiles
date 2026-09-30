import { afterEach, describe, expect, it } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { parseModelRoutingPolicy } from "../model-routing/policy";
import { runSingleAgent, type SingleResult } from "./index";
import { parentBinding } from "./model-routing";
import type { AgentConfig } from "./agents";
import {
	advertiseSubagentLaunchPort,
	LOOM_EMISSION_DESCRIPTOR_MARKER,
	LOOM_SUBAGENT_LAUNCH_CHANNEL,
	type EmissionRpcDirective,
	type SubagentLaunchReply,
	type SubagentLaunchResolveRequest,
	type SubagentLaunchSlot,
} from "./loom-launch-port";

const scratch: string[] = [];

afterEach(() => {
	for (const dir of scratch.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function snapshot() {
	const parsed = parseModelRoutingPolicy({
		schemaVersion: 1,
		defaultClass: "cloud",
		modelClasses: { local: ["desktop-vllm/*"] },
		targets: {},
		rules: [{ id: "local", when: { parentClass: "local" }, use: { kind: "parent" } }],
	});
	if (!parsed.ok) throw new Error(parsed.error.join("\n"));
	return {
		policy: parsed.value,
		policyDigest: "test-digest",
		parent: parentBinding({ provider: "desktop-vllm", id: "deepseek-v4-flash" }, "low"),
	};
}

const agent: AgentConfig = {
	name: "fixture",
	description: "fixture",
	model: "openai-codex/gpt-5.6-sol:high",
	modelProfile: "general-review",
	declaredSkills: [],
	systemPrompt: "",
	source: "user",
	filePath: "/fixture.md",
};

const fakePiSource = `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
const log = (record) => fs.appendFileSync(process.env.FAKE_PI_LOG, JSON.stringify(record) + "\\n");
const mode = args[args.indexOf("--mode") + 1];
log({ kind: "spawn", pid: process.pid, cwd: process.cwd(), args, binding: process.env.LOOM_EMISSION_BINDING ?? null, at: Date.now() });
if (mode === "json") {
  process.stdout.write(JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "json-ok" }], model: "deepseek-v4-flash" } }) + "\\n");
  process.exit(0);
}
let buffer = "";
let readinessInvoked = false;
let selected = { provider: "unset", id: "unset" };
const send = (record) => process.stdout.write(JSON.stringify(record) + "\\n");
process.stdin.on("data", (chunk) => {
  buffer += chunk.toString();
  while (buffer.includes("\\n")) {
    const newline = buffer.indexOf("\\n");
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (!line) continue;
    const command = JSON.parse(line);
    log({ kind: "command", pid: process.pid, command, at: Date.now() });
    const behavior = process.env.FAKE_RPC_BEHAVIOR ?? "success";
    if (behavior === "hang" && command.type === "get_commands") continue;
    if (behavior === "oversize" && command.type === "get_commands") {
      process.stdout.write("x".repeat(1024 * 1024 + 1));
      continue;
    }
    if ((behavior === "refuse" || behavior === "long-refuse") && command.type === "get_commands") {
      send({ id: command.id, type: "response", command: command.type, success: false, error: behavior === "long-refuse" ? "x".repeat(2048) : "startup refused" });
      continue;
    }
    if (command.type === "get_commands") {
      const commands = behavior === "missing-command" ? [] : [{ name: "loom-emission-readiness", source: "extension" }];
      send({ id: command.id, type: "response", command: command.type, success: true, data: { commands } });
      continue;
    }
    if (command.type === "set_model") {
      if (!readinessInvoked) {
        send({ id: command.id, type: "response", command: command.type, success: false, error: "provider not registered before readiness" });
        continue;
      }
      selected = { provider: command.provider, id: command.modelId };
      send({ id: command.id, type: "response", command: command.type, success: true, data: selected });
      continue;
    }
    if (command.type === "get_state") {
      const model = behavior === "wrong-model" ? { provider: selected.provider, id: "wrong-model" } : selected;
      send({ id: command.id, type: "response", command: command.type, success: true, data: { model } });
      continue;
    }
    if (command.type === "prompt" && command.message === "/loom-emission-readiness") {
      readinessInvoked = true;
      const readiness = behavior === "inactive-readiness"
        ? { schema: 1, revision: "r1", active: false }
        : behavior === "wrong-readiness"
          ? { schema: 1, revision: "wrong", active: true }
          : { schema: 1, revision: "r1", active: true };
      const appendReadiness = () => send({ type: "entry_appended", entry: { customType: "loom-emission-readiness", data: readiness } });
      if (behavior === "async-entry") {
        send({ id: command.id, type: "response", command: command.type, success: true });
        setTimeout(appendReadiness, 20);
      } else {
        appendReadiness();
        send({ id: command.id, type: "response", command: command.type, success: true });
      }
      continue;
    }
    if (command.type === "prompt") {
      if (behavior === "task-hang") continue;
      if (behavior === "task-refuse") {
        send({ id: command.id, type: "response", command: command.type, success: false, error: "task refused" });
        continue;
      }
      send({ id: command.id, type: "response", command: command.type, success: true });
      const finish = () => {
        send({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "rpc:" + command.message }], provider: selected.provider, model: selected.id, usage: { input: 2, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 5, cost: { total: 0 } }, stopReason: "stop" } });
        send({ type: "tool_result_end", message: { role: "toolResult", toolCallId: "emission", toolName: "loom_emit", content: [{ type: "text", text: "emitted" }], isError: false, timestamp: Date.now() } });
        send({ type: "agent_settled" });
      };
      setTimeout(finish, behavior === "delayed" ? 120 : 0);
    }
  }
});
`;

function createFakePi(): { dir: string; child: string; logPath: string } {
	const dir = mkdtempSync(join(tmpdir(), "pi-rpc-child-"));
	scratch.push(dir);
	const child = join(dir, "fake-pi");
	const logPath = join(dir, "events.jsonl");
	writeFileSync(child, fakePiSource);
	chmodSync(child, 0o755);
	return { dir, child, logPath };
}

function readLog(logPath: string): Array<Record<string, unknown>> {
	if (!existsSync(logPath)) return [];
	return readFileSync(logPath, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

const FIXTURE_SESSION_ID = "session-fixture";
const WRONG_SESSION_ID = "session-other";

const emissionBinding = Object.freeze({
	toolName: "loom_emit",
	kind: "review",
	version: "v1",
	requestId: "request-1",
	contextDigest: `sha256:${"a".repeat(64)}`,
	schemaDigest: `sha256:${"b".repeat(64)}`,
});

function emissionTask(_slot: SubagentLaunchSlot, suffix = "review"): string {
	const { toolName, kind, version, requestId, contextDigest, schemaDigest } = emissionBinding;
	return [
		`${LOOM_EMISSION_DESCRIPTOR_MARKER} ${toolName} ${kind} ${version} ${requestId} ${contextDigest} ${schemaDigest}`,
		suffix,
	].join("\n");
}

const NOT_ADMITTED: SubagentLaunchReply = Object.freeze({ kind: "not-admitted" });

const admitted = (directive: EmissionRpcDirective): Extract<SubagentLaunchReply, { kind: "emission-rpc" }> =>
	Object.freeze({ kind: "emission-rpc", directive });

function launchPort(
	replyFor: (request: SubagentLaunchResolveRequest) => SubagentLaunchReply,
	readinessTimeoutMs = 500,
	sessionId = FIXTURE_SESSION_ID,
) {
	return (slot: SubagentLaunchSlot) => ({
		sessionId,
		toolCallId: "tool-call",
		slot,
		readinessTimeoutMs,
		events: {
			emit(channel: string, value: unknown) {
				if (channel !== LOOM_SUBAGENT_LAUNCH_CHANNEL) return;
				const request = value as SubagentLaunchResolveRequest;
				if (request.kind === "resolve") {
					const reply = replyFor(request);
					if (reply.kind !== "not-admitted") request.respond(reply);
				}
			},
		},
	});
}

function directive(token: string): EmissionRpcDirective {
	return {
		kind: "emission-rpc",
		bindingEnv: JSON.stringify({ ...emissionBinding, token }),
		expectedProvider: "desktop-vllm",
		expectedModel: "deepseek-v4-flash",
		expectedToolName: emissionBinding.toolName,
		async verifyReadiness(client) {
			const entries = await client.invokeReadiness();
			const entry = entries[0] as { data?: Record<string, unknown> } | undefined;
			if (entry?.data?.schema !== 1 || entry.data.revision !== "r1" || entry.data.active !== true) {
				return { ok: false, reason: "readiness evidence mismatch" };
			}
			await client.setModel("desktop-vllm", "deepseek-v4-flash");
			const state = await client.getState();
			return state.model?.provider === "desktop-vllm" && state.model.id === "deepseek-v4-flash"
				? { ok: true }
				: { ok: false, reason: "route evidence mismatch" };
		},
	};
}

function details(results: SingleResult[]) {
	return { mode: "single" as const, agentScope: "user" as const, projectAgentsDir: null, results };
}

function loggedCommands(logPath: string): Array<Record<string, unknown>> {
	return readLog(logPath)
		.filter((record) => record.kind === "command")
		.map((record) => record.command)
		.filter((command): command is Record<string, unknown> =>
			typeof command === "object" && command !== null && !Array.isArray(command));
}

function expectStartupRefusal(result: SingleResult, slot: SubagentLaunchSlot): void {
	expect(result.exitCode).toBe(1);
	expect(result.launchOutcome).toMatchObject({
		kind: "emission-startup-refused",
		sessionId: FIXTURE_SESSION_ID,
		toolCallId: "tool-call",
		slot,
		requestId: emissionBinding.requestId,
		contextDigest: emissionBinding.contextDigest,
		toolName: emissionBinding.toolName,
		phase: "before-task-prompt",
	});
	expect(Buffer.byteLength(result.launchOutcome?.reason ?? "")).toBeLessThanOrEqual(1024);
}

async function waitFor(predicate: () => boolean, timeoutMs = 500): Promise<void> {
	const startedAt = Date.now();
	while (!predicate()) {
		if (Date.now() - startedAt >= timeoutMs) throw new Error(`condition timed out after ${timeoutMs}ms`);
		await Bun.sleep(5);
	}
}

function ordinaryLaunch() {
	return launchPort(() => NOT_ADMITTED)({ kind: "single", index: 0 });
}

async function usingFakePi<T>(
	behavior: string,
	run: (fixture: ReturnType<typeof createFakePi>) => Promise<T>,
): Promise<T> {
	const fixture = createFakePi();
	const previousExecPath = process.execPath;
	const previousLog = process.env.FAKE_PI_LOG;
	const previousBehavior = process.env.FAKE_RPC_BEHAVIOR;
	Object.defineProperty(process, "execPath", { value: fixture.child, configurable: true });
	process.env.FAKE_PI_LOG = fixture.logPath;
	process.env.FAKE_RPC_BEHAVIOR = behavior;
	try {
		return await run(fixture);
	} finally {
		Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		if (previousLog === undefined) delete process.env.FAKE_PI_LOG;
		else process.env.FAKE_PI_LOG = previousLog;
		if (previousBehavior === undefined) delete process.env.FAKE_RPC_BEHAVIOR;
		else process.env.FAKE_RPC_BEHAVIOR = previousBehavior;
	}
}

describe("subagent execution shell", () => {
	it("advertises launcher capability synchronously on the shared channel", () => {
		const handlers: Array<(event: unknown) => void> = [];
		advertiseSubagentLaunchPort({ on: (_channel, handler) => {
			handlers.push(handler);
			return () => {};
		} });
		const replies: unknown[] = [];
		const probe = Object.freeze({ kind: "capability" as const, version: 2 as const, respond: (reply: unknown) => replies.push(reply) });
		for (const handler of handlers) handler(probe);
		expect(replies).toEqual([{ kind: "available", version: 2 }]);
	});

	it("passes the routed exact model and thinking args to the child process", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-child-argv-"));
		scratch.push(dir);
		const argvPath = join(dir, "argv.json");
		const child = join(dir, "fake-pi");
		writeFileSync(child, `#!/usr/bin/env bash\nprintf '%s\\n' "$@" | jq -Rs 'split("\\n")[:-1]' > ${JSON.stringify(argvPath)}\nprintf '%s\\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"model":"deepseek-v4-flash"}}'\n`);
		chmodSync(child, 0o755);
		const previousExecPath = process.execPath;
		Object.defineProperty(process, "execPath", { value: child, configurable: true });
		try {
			const result = await runSingleAgent(
				dir,
				[agent],
				agent.name,
				"task",
				undefined,
				undefined,
				undefined,
				undefined,
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }),
				snapshot(),
				ordinaryLaunch(),
			);
			expect(result.exitCode).toBe(0);
			const argv = JSON.parse(readFileSync(argvPath, "utf8")) as string[];
			expect(argv).toContain("desktop-vllm/deepseek-v4-flash");
			expect(argv).toContain("low");
			expect(argv).not.toContain("openai-codex/gpt-5.6-sol:high");
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});

	it("preserves the underlying spawn error", async () => {
		const previousExecPath = process.execPath;
		Object.defineProperty(process, "execPath", { value: "/definitely/missing/pi", configurable: true });
		try {
			const result = await runSingleAgent(
				"/definitely/missing/cwd",
				[agent],
				agent.name,
				"task",
				undefined,
				undefined,
				undefined,
				undefined,
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }),
				snapshot(),
				ordinaryLaunch(),
			);
			expect(result.exitCode).toBe(1);
			expect(result.errorMessage).toContain("Failed to spawn subagent process");
			expect(result.stderr).toMatch(/ENOENT|no such file/i);
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});

	it("turns mixed valid and malformed protocol output into a diagnostic failure", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-child-protocol-"));
		scratch.push(dir);
		const child = join(dir, "fake-pi");
		writeFileSync(child, "#!/usr/bin/env bash\nprintf '%s\\n' '{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}}' 'not-json' '42'\n");
		chmodSync(child, 0o755);
		const previousExecPath = process.execPath;
		Object.defineProperty(process, "execPath", { value: child, configurable: true });
		try {
			const result = await runSingleAgent(
				dir,
				[agent],
				agent.name,
				"task",
				undefined,
				undefined,
				undefined,
				undefined,
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }),
				snapshot(),
				ordinaryLaunch(),
			);
			expect(result.exitCode).toBe(1);
			expect(result.errorMessage).toContain("malformed JSON protocol output");
			expect(result.protocolErrors).toEqual(["not-json", "42"]);
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});

	it("reports signal termination as a failure", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-child-signal-"));
		scratch.push(dir);
		const child = join(dir, "fake-pi");
		writeFileSync(child, "#!/usr/bin/env bash\nkill -TERM $$\n");
		chmodSync(child, 0o755);
		const previousExecPath = process.execPath;
		Object.defineProperty(process, "execPath", { value: child, configurable: true });
		try {
			const result = await runSingleAgent(
				dir, [agent], agent.name, "task", undefined, undefined, undefined, undefined,
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }), snapshot(), ordinaryLaunch(),
			);
			expect(result.exitCode).toBe(1);
			expect(result.errorMessage).toContain("terminated by signal SIGTERM");
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});

	it("returns an aborted result (no throw) when the signal fires mid-run", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-child-abort-"));
		scratch.push(dir);
		const child = join(dir, "fake-pi");
		// exec sleep: SIGTERM terminates the process itself, so the close handler
		// sees childSignal=SIGTERM exactly like a real killed child.
		writeFileSync(child, "#!/usr/bin/env bash\nexec sleep 30\n");
		chmodSync(child, 0o755);
		const previousExecPath = process.execPath;
		Object.defineProperty(process, "execPath", { value: child, configurable: true });
		const controller = new AbortController();
		try {
			const promise = runSingleAgent(
				dir, [agent], agent.name, "task", undefined, undefined, controller.signal, undefined,
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }), snapshot(), ordinaryLaunch(),
			);
			setTimeout(() => controller.abort(), 150);
			const result = await promise;
			expect(result.exitCode).toBe(1);
			expect(result.stopReason).toBe("aborted");
			expect(result.errorMessage).toMatch(/aborted/i);
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});

	it("returns an aborted result immediately when the signal is already aborted", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-child-preabort-"));
		scratch.push(dir);
		const child = join(dir, "fake-pi");
		writeFileSync(child, "#!/usr/bin/env bash\nprintf '%s\\n' '{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"should not run\"}]}}'\n");
		chmodSync(child, 0o755);
		const previousExecPath = process.execPath;
		Object.defineProperty(process, "execPath", { value: child, configurable: true });
		const controller = new AbortController();
		controller.abort();
		try {
			const result = await runSingleAgent(
				dir, [agent], agent.name, "task", undefined, undefined, controller.signal, undefined,
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }), snapshot(), ordinaryLaunch(),
			);
			expect(result.stopReason).toBe("aborted");
			expect(result.messages).toEqual([]);
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});

	it("keeps a not-admitted ordinary launch on the unchanged JSON path", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const previous = process.env.LOOM_EMISSION_BINDING;
			process.env.LOOM_EMISSION_BINDING = "must-not-leak";
			try {
				let responderObserved = false;
				const result = await runSingleAgent(
					dir, [agent], agent.name, "ordinary", undefined, undefined, undefined, undefined,
					details, snapshot(), launchPort((request) => {
					expect(request.sessionId).toBe(FIXTURE_SESSION_ID);
					responderObserved = typeof request.respond === "function";
					return NOT_ADMITTED;
				})({ kind: "single", index: 0 }),
				);
				expect(responderObserved).toBe(true);
				expect(result.exitCode).toBe(0);
				expect(result.messages[0]?.role).toBe("assistant");
				const spawn = readLog(logPath).find((record) => record.kind === "spawn");
				expect(spawn?.binding).toBeNull();
				expect(spawn?.args).toContain("json");
				expect(spawn?.args).toContain("Task: ordinary");
			} finally {
				if (previous === undefined) delete process.env.LOOM_EMISSION_BINDING;
				else process.env.LOOM_EMISSION_BINDING = previous;
			}
		});
	});

	it("resolves relative item cwd identically for admission and JSON or emission launch", async () => {
		for (const branch of ["json", "emission"] as const) {
			await usingFakePi("success", async ({ dir, logPath }) => {
				const relativeCwd = `relative-${branch}`;
				const expectedCwd = resolve(dir, relativeCwd);
				mkdirSync(expectedCwd);
				let admittedCwd: string | undefined;
				const slot = { kind: "single", index: 0 } as const;
				const result = await runSingleAgent(
					dir,
					[agent],
					agent.name,
					branch === "emission" ? emissionTask(slot, "relative cwd") : "relative cwd",
					relativeCwd,
					undefined,
					undefined,
					undefined,
					details,
					snapshot(),
					launchPort((request) => {
						admittedCwd = request.cwd;
						return branch === "emission" ? admitted(directive("relative-cwd")) : NOT_ADMITTED;
					})(slot),
				);

				expect(result.exitCode).toBe(0);
				const spawnedCwd = readLog(logPath).find((record) => record.kind === "spawn")?.cwd;
				expect(admittedCwd).toBe(expectedCwd);
				expect(spawnedCwd).toBe(expectedCwd);
				expect(spawnedCwd).toBe(admittedCwd);
			});
		}
	});

	it("fails closed before spawn when two listeners try to answer one launch request", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const result = await runSingleAgent(
				dir, [agent], agent.name, emissionTask(slot), undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort((request) => {
					request.respond(admitted(directive("first")));
					return admitted(directive("second"));
				})(slot),
			);
			expect(result.exitCode).toBe(1);
			expect(result.errorMessage).toContain("more than once");
			expect(readLog(logPath)).toEqual([]);
		});
	});

	it("uses an authorized emission-RPC reply to register the exact route before launch", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "parallel", index: 4 } as const;
			const task = emissionTask(slot, "T5:code-reviewer-4");
			const result = await runSingleAgent(
				dir, [{ ...agent, tools: ["read"] }], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => admitted(directive("item-4")))(slot),
			);
			expect(result.exitCode).toBe(0);
			expect(result.launchOutcome).toBeUndefined();
			expect(result.usage).toMatchObject({ input: 2, output: 3, turns: 1, contextTokens: 5 });
			expect(result.messages.map((message) => message.role)).toEqual(["assistant", "toolResult"]);

			const records = readLog(logPath);
			const spawn = records.find((record) => record.kind === "spawn");
			expect(spawn?.binding).toBe(JSON.stringify({ ...emissionBinding, token: "item-4" }));
			expect(spawn?.args).toContain("rpc");
			expect(spawn?.args).not.toContain("-p");
			expect(spawn?.args).not.toContain(`Task: ${task}`);
			expect(spawn?.args).toContain("read,loom_emit");
			const commands = loggedCommands(logPath);
			expect(commands.map((command) => command.type)).toEqual([
				"get_commands", "prompt", "set_model", "get_state", "prompt",
			]);
			expect(commands[1]?.message).toBe("/loom-emission-readiness");
			expect(commands[4]?.message).toBe(task);
		});
	});

	it("awaits readiness evidence appended after the command acknowledgement", async () => {
		await usingFakePi("async-entry", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot, "async readiness");
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => admitted(directive("async-entry")))(slot),
			);
			expect(result.exitCode).toBe(0);
			const commands = loggedCommands(logPath);
			expect(commands.map((command) => command.type)).toEqual([
				"get_commands", "prompt", "set_model", "get_state", "prompt",
			]);
			expect(commands.at(-1)?.message).toBe(task);
		});
	});

	it("refuses malformed or duplicate space-delimited descriptors before spawn", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const descriptor = emissionTask(slot).split("\n")[0];
			const malformedTasks = [
				`${LOOM_EMISSION_DESCRIPTOR_MARKER} loom_emit review v1 request-1 context-only`,
				`${LOOM_EMISSION_DESCRIPTOR_MARKER}  loom_emit review v1 request-1 context schema`,
				`${LOOM_EMISSION_DESCRIPTOR_MARKER} loom_emit review v1 request-1 context schema extra`,
				`${LOOM_EMISSION_DESCRIPTOR_MARKER} loom_emit\treview v1 request-1 context schema`,
				`${descriptor}\n${descriptor}`,
			];
			for (const task of malformedTasks) {
				const result = await runSingleAgent(
					dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
					details, snapshot(), launchPort(() => admitted(directive("malformed")))(slot),
				);
				expect(result.exitCode).toBe(1);
				expect(result.launchOutcome).toBeUndefined();
			}
			expect(readLog(logPath)).toEqual([]);
		});
	});

	it("compares every descriptor field with the independently provisioned binding before spawn", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot);
			for (const field of ["toolName", "kind", "version", "requestId", "contextDigest", "schemaDigest"] as const) {
				const changed = field === "toolName" ? "loom_emit_other" : `${emissionBinding[field]}-other`;
				const mismatched = {
					...directive(field),
					bindingEnv: JSON.stringify({ ...emissionBinding, [field]: changed }),
					...(field === "toolName" ? { expectedToolName: changed } : {}),
				};
				const result = await runSingleAgent(
					dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
					details, snapshot(), launchPort(() => admitted(mismatched))(slot),
				);
				expect(result.errorMessage).toContain(`descriptor mismatch: ${field}`);
				expect(result.launchOutcome).toBeUndefined();
			}
			expect(readLog(logPath)).toEqual([]);
		});
	});

	it("fails closed before spawning when a descriptor is not admitted or its route mismatches", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot);
			const missing = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => NOT_ADMITTED)(slot),
			);
			expect(missing.exitCode).toBe(1);
			expect(missing.errorMessage).toContain("not admitted for emission RPC");
			expect(missing.launchOutcome).toBeUndefined();
			expect(readLog(logPath)).toEqual([]);

			const wrongRoute = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => admitted({
					...directive("wrong"),
					expectedModel: "not-the-routed-model",
				}))(slot),
			);
			expect(wrongRoute.errorMessage).toContain("does not match");
			expect(wrongRoute.launchOutcome).toBeUndefined();
			expect(readLog(logPath)).toEqual([]);
		});
	});

	it("fails closed on an explicit refusal without spawning or sending the task prompt", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot);
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => ({
					kind: "refused",
					reason: "issued launch was revoked",
				}))(slot),
			);
			expect(result.exitCode).toBe(1);
			expect(result.errorMessage).toContain("issued launch was revoked");
			expect(result.launchOutcome).toBeUndefined();
			expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
			expect(readLog(logPath)).toEqual([]);
		});
	});

	for (const behavior of [
		"missing-command",
		"inactive-readiness",
		"wrong-readiness",
		"wrong-model",
		"refuse",
		"long-refuse",
	] as const) {
		it(`marks proven ${behavior} startup refusal without sending the task prompt`, async () => {
			await usingFakePi(behavior, async ({ dir, logPath }) => {
				const slot = { kind: "single", index: 0 } as const;
				const task = emissionTask(slot);
				const result = await runSingleAgent(
					dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
					details, snapshot(), launchPort(() => admitted(directive(behavior)))(slot),
				);
				expectStartupRefusal(result, slot);
				expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
			});
		});
	}

	it("bounds RPC records and kills an oversized child without sending the task", async () => {
		await usingFakePi("oversize", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot);
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => admitted(directive("oversize")), 2_000)(slot),
			);
			expect(result.errorMessage).toContain("RPC record exceeded");
			expectStartupRefusal(result, slot);
			expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
		});
	});

	it("refuses a verifier that omits post-readiness model selection", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot);
			const incomplete: EmissionRpcDirective = {
				...directive("incomplete"),
				async verifyReadiness(client) {
					await client.invokeReadiness();
					return { ok: true };
				},
			};
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => admitted(incomplete))(slot),
			);
			expect(result.errorMessage).toContain("must select desktop-vllm/deepseek-v4-flash after readiness");
			expectStartupRefusal(result, slot);
			expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
		});
	});

	it("refuses a verifier that omits exact post-selection state observation", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot);
			const incomplete: EmissionRpcDirective = {
				...directive("no-state"),
				async verifyReadiness(client) {
					await client.invokeReadiness();
					await client.setModel("desktop-vllm", "deepseek-v4-flash");
					return { ok: true };
				},
			};
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => admitted(incomplete))(slot),
			);
			expect(result.errorMessage).toContain("must observe exact route desktop-vllm/deepseek-v4-flash");
			expectStartupRefusal(result, slot);
			expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
		});
	});

	it("honors readiness verifier refusal without sending the task prompt", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot);
			const refused: EmissionRpcDirective = {
				...directive("refused"),
				async verifyReadiness(client) {
					await client.invokeReadiness();
					return { ok: false, reason: "issued revision was revoked" };
				},
			};
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
				details, snapshot(), launchPort(() => admitted(refused))(slot),
			);
			expect(result.errorMessage).toContain("issued revision was revoked");
			expectStartupRefusal(result, slot);
			expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
		});
	});

	it("times out and aborts readiness without ever sending the task prompt", async () => {
		for (const mode of ["timeout", "abort"] as const) {
			await usingFakePi("hang", async ({ dir, logPath }) => {
				const slot = { kind: "single", index: 0 } as const;
				const task = emissionTask(slot, mode);
				const controller = new AbortController();
				if (mode === "abort") setTimeout(() => controller.abort(), 30);
				const result = await runSingleAgent(
					dir, [agent], agent.name, task, undefined, undefined,
					mode === "abort" ? controller.signal : undefined, undefined,
					details, snapshot(), launchPort(() => admitted(directive(mode)), 50)(slot),
				);
				expect(result.exitCode).toBe(1);
				if (mode === "abort") expect(result.stopReason).toBe("aborted");
				else expect(result.errorMessage).toContain("timed out after 50ms");
				expectStartupRefusal(result, slot);
				expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
			});
		}
	});

	for (const behavior of ["task-refuse", "task-hang"] as const) {
		it(`never marks ${behavior} after the Task RPC prompt write`, async () => {
			await usingFakePi(behavior, async ({ dir, logPath }) => {
				const slot = { kind: "single", index: 0 } as const;
				const task = emissionTask(slot, behavior);
				const result = await runSingleAgent(
					dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
					details, snapshot(), launchPort(() => admitted(directive(behavior)), 50)(slot),
				);
				expect(result.exitCode).toBe(1);
				expect(result.launchOutcome).toBeUndefined();
				expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(true);
				if (behavior === "task-refuse") expect(result.errorMessage).toContain("task refused");
				else expect(result.errorMessage).toContain("Task prompt timed out after 50ms");
			});
		});
	}

	it("marks cancellation before Task write but not cancellation after Task write", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot, "already cancelled");
			const controller = new AbortController();
			controller.abort();
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, controller.signal, undefined,
				details, snapshot(), launchPort(() => admitted(directive("already-cancelled")))(slot),
			);
			expect(result.stopReason).toBe("aborted");
			expectStartupRefusal(result, slot);
			expect(readLog(logPath)).toEqual([]);
		});

		await usingFakePi("hang", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot, "pre-prompt cancellation");
			const controller = new AbortController();
			setTimeout(() => controller.abort(), 20);
			const result = await runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, controller.signal, undefined,
				details, snapshot(), launchPort(() => admitted(directive("pre-cancel")), 200)(slot),
			);
			expect(result.stopReason).toBe("aborted");
			expectStartupRefusal(result, slot);
			expect(loggedCommands(logPath).some((command) => command.message === task)).toBe(false);
		});

		await usingFakePi("delayed", async ({ dir, logPath }) => {
			const slot = { kind: "single", index: 0 } as const;
			const task = emissionTask(slot, "post-prompt cancellation");
			const controller = new AbortController();
			const pending = runSingleAgent(
				dir, [agent], agent.name, task, undefined, undefined, controller.signal, undefined,
				details, snapshot(), launchPort(() => admitted(directive("post-cancel")), 200)(slot),
			);
			await waitFor(() => loggedCommands(logPath).some((command) => command.message === task));
			controller.abort();
			const result = await pending;
			expect(result.exitCode).toBe(1);
			expect(result.stopReason).toBe("aborted");
			expect(result.launchOutcome).toBeUndefined();
		});
	});

	it("fails parallel and chain requests whose session does not match the staged launch", async () => {
		await usingFakePi("success", async ({ dir, logPath }) => {
			for (const slot of [
				{ kind: "parallel", index: 2 } as const,
				{ kind: "chain", index: 1 } as const,
			]) {
				const task = emissionTask(slot, `${slot.kind} session mismatch`);
				const result = await runSingleAgent(
					dir, [agent], agent.name, task, undefined, undefined, undefined, undefined,
					details,
					snapshot(),
					launchPort((request) => request.sessionId === FIXTURE_SESSION_ID
						? admitted(directive("unexpected"))
						: { kind: "refused", reason: "session mismatch" }, 500, WRONG_SESSION_ID)(slot),
				);
				expect(result.exitCode).toBe(1);
				expect(result.errorMessage).toContain("session mismatch");
				expect(result.launchOutcome).toBeUndefined();
			}
			expect(readLog(logPath)).toEqual([]);
		});
	});

	it("isolates per-child bindings and preserves original concurrent item slots", async () => {
		await usingFakePi("delayed", async ({ dir, logPath }) => {
			const seenSlots: number[] = [];
			const seenSessions: string[] = [];
			const port = launchPort((request) => {
				seenSlots.push(request.slot.index);
				seenSessions.push(request.sessionId);
				return admitted(directive(`item-${request.slot.index}`));
			});
			const slots = [
				{ kind: "parallel", index: 2 } as const,
				{ kind: "parallel", index: 7 } as const,
			];
			const results = await Promise.all(slots.map((slot) => runSingleAgent(
				dir, [agent], agent.name, emissionTask(slot, `item-${slot.index}`), undefined, undefined,
				undefined, undefined, details, snapshot(), port(slot),
			)));
			expect(results.every((result) => result.exitCode === 0)).toBe(true);
			expect(seenSlots.sort((a, b) => a - b)).toEqual([2, 7]);
			expect(seenSessions).toEqual([FIXTURE_SESSION_ID, FIXTURE_SESSION_ID]);
			const bindings = readLog(logPath)
				.filter((record) => record.kind === "spawn")
				.map((record) => JSON.parse(String(record.binding)).token)
				.sort();
			expect(bindings).toEqual(["item-2", "item-7"]);
			const taskCommands = loggedCommands(logPath).filter((command) =>
				typeof command.message === "string" && !command.message.startsWith("/"));
			const taskTimes = readLog(logPath)
				.filter((record) => record.kind === "command" && taskCommands.some((command) => command.id === (record.command as Record<string, unknown>).id))
				.map((record) => Number(record.at));
			expect(Math.max(...taskTimes) - Math.min(...taskTimes)).toBeLessThan(100);
		});
	});

	it("keeps chain step slots stable when previous output changes the next task", async () => {
		await usingFakePi("success", async ({ dir }) => {
			const observed: Array<{ index: number; sessionId: string; task: string }> = [];
			const port = launchPort((request) => {
				observed.push({ index: request.slot.index, sessionId: request.sessionId, task: request.task });
				return admitted(directive(`step-${request.slot.index}`));
			});
			const firstSlot = { kind: "chain", index: 0 } as const;
			const first = await runSingleAgent(
				dir, [agent], agent.name, emissionTask(firstSlot, "first"), undefined, 1, undefined, undefined,
				details, snapshot(), port(firstSlot),
			);
			const previous = (first.messages[0]?.content[0] as { text?: string } | undefined)?.text ?? "";
			const secondSlot = { kind: "chain", index: 1 } as const;
			const secondTemplate = emissionTask(secondSlot, "consume {previous}");
			const secondTask = secondTemplate.replace(/\{previous\}/g, previous);
			const second = await runSingleAgent(
				dir, [agent], agent.name, secondTask, undefined, 2, undefined, undefined,
				details, snapshot(), port(secondSlot),
			);
			expect(first.exitCode).toBe(0);
			expect(second.exitCode).toBe(0);
			expect(observed.map(({ index }) => index)).toEqual([0, 1]);
			expect(observed.map(({ sessionId }) => sessionId)).toEqual([FIXTURE_SESSION_ID, FIXTURE_SESSION_ID]);
			expect(observed[1]?.task).toContain(previous);
		});
	});

	it("surfaces temporary prompt cleanup failures", async () => {
		const dir = mkdtempSync(join(tmpdir(), "pi-child-cleanup-"));
		scratch.push(dir);
		const child = join(dir, "fake-pi");
		writeFileSync(child, "#!/usr/bin/env bash\nprompt=''\nwhile [ $# -gt 0 ]; do if [ \"$1\" = --append-system-prompt ]; then prompt=$2; shift 2; else shift; fi; done\nmkdir \"$prompt.blocker\"\nprintf '%s\\n' '{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}'\n");
		chmodSync(child, 0o755);
		const previousExecPath = process.execPath;
		Object.defineProperty(process, "execPath", { value: child, configurable: true });
		try {
			const result = await runSingleAgent(
				dir, [{ ...agent, systemPrompt: "prompt" }], agent.name, "task", undefined, undefined, undefined, undefined,
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }), snapshot(), ordinaryLaunch(),
			);
			expect(result.stderr).toContain("Failed to remove temporary prompt directory");
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});
});
