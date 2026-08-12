import { afterEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadModelRoutingPolicy } from "./config";

const scratch: string[] = [];

afterEach(() => {
	for (const dir of scratch.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function fixture(): string {
	const agentDir = mkdtempSync(join(tmpdir(), "pi-model-routing-"));
	scratch.push(agentDir);
	mkdirSync(agentDir, { recursive: true });
	return agentDir;
}

const policy = (ruleId = "local-parent") => JSON.stringify({
	schemaVersion: 1,
	defaultClass: "cloud",
	modelClasses: { local: ["desktop-vllm/*"] },
	targets: {},
	rules: [{ id: ruleId, when: { parentClass: "local" }, use: { kind: "parent" } }],
});

describe("model routing policy loader", () => {
	it("returns a content digest that changes with the execution policy", () => {
		const agentDir = fixture();
		const path = join(agentDir, "model-routing.json");
		writeFileSync(path, policy());
		const first = loadModelRoutingPolicy(agentDir);
		expect(first.ok).toBe(true);
		if (!first.ok) return;

		writeFileSync(path, policy("renamed-rule"));
		const second = loadModelRoutingPolicy(agentDir);
		expect(second.ok).toBe(true);
		if (!second.ok) return;
		expect(second.value.digest).not.toBe(first.value.digest);
		expect(second.value.digest).toHaveLength(64);
	});

	it("returns a typed failure for malformed or missing policy files", () => {
		const agentDir = fixture();
		writeFileSync(join(agentDir, "model-routing.json"), "not-json");
		const malformed = loadModelRoutingPolicy(agentDir);
		expect(malformed.ok).toBe(false);
		if (!malformed.ok) expect(malformed.error.path).toEndWith("model-routing.json");

		rmSync(join(agentDir, "model-routing.json"));
		const missing = loadModelRoutingPolicy(agentDir);
		expect(missing.ok).toBe(false);
	});
});
