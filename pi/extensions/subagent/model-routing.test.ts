import { describe, expect, it } from "bun:test";
import { parseModelReference, parseModelRoutingPolicy } from "../model-routing/policy";
import type { ServedModelSource } from "../model-routing/served";
import { bindingArguments, buildRoutingSnapshot, parentBinding, resolveSubagentRoute } from "./model-routing";

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

	it("launches children on the model the provider serves now, with the probe's reason on failure", () => {
		const parsed = parseModelRoutingPolicy({
			schemaVersion: 1,
			defaultClass: "cloud",
			modelClasses: { local: ["desktop-vllm/*"] },
			targets: { local: { served: "desktop-vllm" } },
			rules: [{ id: "all-children-local", when: {}, use: { kind: "named", target: "local" } }],
		});
		if (!parsed.ok) throw new Error(parsed.error.join("\n"));
		const parent = parentBinding({ provider: "desktop-vllm", id: "warmind-1017-native" }, "high");
		const glm = parseModelReference("desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16");
		if (!glm.ok) throw new Error(glm.error);

		const routed = resolveSubagentRoute(
			{ policy: parsed.value, policyDigest: "abc", parent, served: { "desktop-vllm": { ok: true, value: glm.value } } },
			loomAgent,
		);
		expect(routed.ok).toBe(true);
		if (!routed.ok) return;
		expect(routed.value.args).toEqual(["--model", "desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16", "--thinking", "high"]);

		const down = resolveSubagentRoute(
			{
				policy: parsed.value,
				policyDigest: "abc",
				parent,
				served: { "desktop-vllm": { ok: false, error: "cannot reach desktop-vllm: connect ECONNREFUSED" } },
			},
			loomAgent,
		);
		expect(down.ok).toBe(false);
		if (down.ok) return;
		expect(down.error).toContain("all-children-local");
		expect(down.error).toContain("ECONNREFUSED");
	});

	it("builds one snapshot per tool call: one probe for a whole batch, none without a served rule", async () => {
		let probes = 0;
		const source: ServedModelSource = {
			baseUrl: () => "http://desktop:8000/v1",
			apiKey: async () => "key",
			inCatalog: () => true,
			fetchJson: async () => {
				probes++;
				return { data: [{ id: "glm-5.3-flash-hyperflare-tp2-v16" }] };
			},
		};
		const servedPolicy = parseModelRoutingPolicy({
			schemaVersion: 1,
			defaultClass: "cloud",
			modelClasses: { local: ["desktop-vllm/*"] },
			targets: { local: { served: "desktop-vllm" } },
			rules: [{ id: "all-children-local", when: {}, use: { kind: "named", target: "local" } }],
		});
		if (!servedPolicy.ok) throw new Error(servedPolicy.error.join("\n"));

		const snapshot = await buildRoutingSnapshot({ policy: servedPolicy.value, digest: "d" }, undefined, source);
		const batch = ["code-reviewer", "planner", "worker"].map((name) =>
			resolveSubagentRoute(snapshot, { name, model: undefined, modelProfile: undefined }));
		expect(probes).toBe(1);
		expect(batch.map((route) => (route.ok ? route.value.audit.effective : route.error))).toEqual([
			"desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16",
			"desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16",
			"desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16",
		]);

		const plain = await buildRoutingSnapshot({ policy: policy(), digest: "d" }, undefined, source);
		expect(probes).toBe(1);
		expect(plain.served).toBeUndefined();
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
