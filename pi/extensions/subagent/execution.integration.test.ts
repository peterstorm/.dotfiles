import { afterEach, describe, expect, it } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseModelRoutingPolicy } from "../model-routing/policy";
import { runSingleAgent } from "./index";
import { parentBinding } from "./model-routing";
import type { AgentConfig } from "./agents";

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

describe("subagent execution shell", () => {
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
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }), snapshot(),
			);
			expect(result.exitCode).toBe(1);
			expect(result.errorMessage).toContain("terminated by signal SIGTERM");
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
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
				(results) => ({ mode: "single", agentScope: "user", projectAgentsDir: null, results }), snapshot(),
			);
			expect(result.stderr).toContain("Failed to remove temporary prompt directory");
		} finally {
			Object.defineProperty(process, "execPath", { value: previousExecPath, configurable: true });
		}
	});
});
