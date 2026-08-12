import { describe, expect, it } from "bun:test";
import { parseModelRoutingPolicy } from "../model-routing/policy";
import { bindingArguments, parentBinding, resolveSubagentRoute } from "./model-routing";

function policy() {
	const parsed = parseModelRoutingPolicy({
		schemaVersion: 1,
		defaultClass: "cloud",
		modelClasses: { local: ["desktop-vllm/*"] },
		targets: {},
		rules: [{
			id: "local-workloads-use-parent",
			when: { parentClass: "local" },
			use: { kind: "parent" },
		}],
	});
	if (!parsed.ok) throw new Error(parsed.error.join("\n"));
	return parsed.value;
}

const loomAgent = {
	name: "code-reviewer",
	model: "openai-codex/gpt-5.6-sol:high",
	modelProfile: "general-review",
};

describe("subagent model routing adapter", () => {
	it("launches local children with an exact model and thinking level", () => {
		const parent = parentBinding({ provider: "desktop-vllm", id: "deepseek-v4-flash" }, "max");
		const routed = resolveSubagentRoute({ policy: policy(), policyDigest: "abc", parent }, loomAgent);
		expect(routed.ok).toBe(true);
		if (!routed.ok) return;

		expect(routed.value.args).toEqual([
			"--model",
			"desktop-vllm/deepseek-v4-flash",
			"--thinking",
			"max",
		]);
		expect(routed.value.audit).toEqual({
			decision: "override",
			declared: "openai-codex/gpt-5.6-sol:high",
			effective: "desktop-vllm/deepseek-v4-flash:max",
			parentClass: "local",
			ruleId: "local-workloads-use-parent",
			policyDigest: "abc",
		});
	});

	it("retains Loom's calibrated launch binding for cloud parents", () => {
		const parent = parentBinding({ provider: "openai-codex", id: "gpt-5.6-sol" }, "max");
		const routed = resolveSubagentRoute({ policy: policy(), policyDigest: "abc", parent }, loomAgent);
		expect(routed.ok).toBe(true);
		if (!routed.ok) return;
		expect(routed.value.args).toEqual([
			"--model",
			"openai-codex/gpt-5.6-sol:high",
		]);
		expect(routed.value.audit.decision).toBe("declared");
	});

	it("leaves generic cloud children on Pi's configured default", () => {
		const parent = parentBinding({ provider: "anthropic", id: "claude-opus-4-6" }, "high");
		const routed = resolveSubagentRoute(
			{ policy: policy(), policyDigest: "abc", parent },
			{ name: "planner", model: undefined, modelProfile: undefined },
		);
		expect(routed.ok).toBe(true);
		if (!routed.ok) return;
		expect(routed.value.args).toEqual([]);
		expect(routed.value.audit.effective).toBeUndefined();
	});

	it("overrides generic children when the active parent is local", () => {
		const parent = parentBinding({ provider: "desktop-vllm", id: "future-model" }, "low");
		const routed = resolveSubagentRoute(
			{ policy: policy(), policyDigest: "abc", parent },
			{ name: "planner", model: undefined, modelProfile: undefined },
		);
		expect(routed.ok).toBe(true);
		if (!routed.ok) return;
		expect(routed.value.args).toEqual([
			"--model",
			"desktop-vllm/future-model",
			"--thinking",
			"low",
		]);
	});

	it("copies the parent binding so a later model switch cannot drift a batch", () => {
		const active = { provider: "desktop-vllm", id: "deepseek-v4-flash" };
		const parent = parentBinding(active, "max");
		active.id = "switched-after-snapshot";
		const routed = resolveSubagentRoute({ policy: policy(), policyDigest: "abc", parent }, loomAgent);
		expect(routed.ok).toBe(true);
		if (!routed.ok) return;
		expect(routed.value.audit.effective).toBe("desktop-vllm/deepseek-v4-flash:max");
	});

	it("does not construct a fallback model list", () => {
		expect(bindingArguments(parentBinding(
			{ provider: "desktop-vllm", id: "deepseek-v4-flash" },
			"max",
		))).toEqual([
			"--model",
			"desktop-vllm/deepseek-v4-flash",
			"--thinking",
			"max",
		]);
	});

	it("preserves Pi-supported aliases and colon-bearing model IDs under cloud parents", () => {
		for (const model of ["sonnet", "ollama/qwen2.5-coder:7b"]) {
			const routed = resolveSubagentRoute(
				{
					policy: policy(),
					policyDigest: "abc",
					parent: parentBinding({ provider: "openai-codex", id: "gpt-5.6-sol" }, "high"),
				},
				{ name: "catalog-expression", model, modelProfile: undefined },
			);
			expect(routed.ok).toBe(true);
			if (!routed.ok) continue;
			expect(routed.value.args).toEqual(["--model", model]);
			expect(routed.value.audit.declared).toBe(model);
			expect(routed.value.audit.effective).toBe(model);
		}
	});

	it("does not parse an opaque declaration before applying a local override", () => {
		const routed = resolveSubagentRoute(
			{
				policy: policy(),
				policyDigest: "abc",
				parent: parentBinding({ provider: "desktop-vllm", id: "deepseek-v4-flash" }, "low"),
			},
			{ name: "catalog-expression", model: "ollama/qwen2.5-coder:7b", modelProfile: undefined },
		);
		expect(routed.ok).toBe(true);
		if (!routed.ok) return;
		expect(routed.value.args).toEqual([
			"--model",
			"desktop-vllm/deepseek-v4-flash",
			"--thinking",
			"low",
		]);
	});
});
