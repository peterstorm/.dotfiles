import { describe, expect, it } from "bun:test";
import {
	classifyModel,
	formatModelBinding,
	parseModelBinding,
	parseModelReference,
	parseModelRoutingPolicy,
	resolveModelRoute,
	routingErrorMessage,
	servedProviders,
	type ModelRoutingPolicy,
} from "./policy";

function parsePolicy(overrides: Record<string, unknown> = {}): ModelRoutingPolicy {
	const parsed = parseModelRoutingPolicy({
		schemaVersion: 1,
		defaultClass: "cloud",
		modelClasses: { local: ["desktop-vllm/*", "ollama/qwen-coder"] },
		targets: {
			fast: { model: "openai-codex/gpt-5.4-mini", thinkingLevel: "medium" },
		},
		rules: [
			{
				id: "local-parent",
				when: { parentClass: "local" },
				use: { kind: "parent" },
			},
		],
		...overrides,
	});
	if (!parsed.ok) throw new Error(parsed.error.join("\n"));
	return parsed.value;
}

const binding = (provider: string, id: string, thinkingLevel?: "low" | "medium" | "high" | "max") => {
	const model = parseModelReference(`${provider}/${id}`);
	if (!model.ok) throw new Error(model.error);
	return { model: model.value, ...(thinkingLevel ? { thinkingLevel } : {}) };
};

describe("model binding", () => {
	it("round-trips an exact model with a thinking suffix", () => {
		const parsed = parseModelBinding("openai-codex/gpt-5.6-sol:high");
		expect(parsed.ok).toBe(true);
		if (!parsed.ok) return;
		expect(formatModelBinding(parsed.value)).toBe("openai-codex/gpt-5.6-sol:high");
	});

	it("rejects patterns and malformed thinking levels as launch bindings", () => {
		expect(parseModelBinding("desktop-vllm/*").ok).toBe(false);
		expect(parseModelBinding("desktop-vllm/deepseek-v4-flash:turbo").ok).toBe(false);
	});
});

describe("Pi model routing policy", () => {
	it("classifies only explicitly configured models as local", () => {
		const policy = parsePolicy();
		expect(classifyModel(policy, { provider: "desktop-vllm", id: "deepseek-v4-flash" })).toEqual({
			ok: true,
			value: "local",
		});
		expect(classifyModel(policy, { provider: "openai-codex", id: "gpt-5.6-sol" })).toEqual({
			ok: true,
			value: "cloud",
		});
	});

	it("rejects overlapping model classes instead of guessing locality", () => {
		const parsed = parseModelRoutingPolicy({
			schemaVersion: 1,
			defaultClass: "cloud",
			modelClasses: {
				local: ["desktop-vllm/*"],
				workstation: ["desktop-vllm/deepseek-v4-flash"],
			},
			targets: {},
			rules: [],
		});
		expect(parsed.ok).toBe(false);
		if (parsed.ok) return;
		expect(parsed.error.join("\n")).toContain("model classes local and workstation overlap");
	});

	it("rejects equal-specificity rules that could both match", () => {
		const parsed = parseModelRoutingPolicy({
			schemaVersion: 1,
			defaultClass: "cloud",
			modelClasses: { local: ["desktop-vllm/*"] },
			targets: {},
			rules: [
				{ id: "profile", when: { parentClass: "local", profile: "review" }, use: { kind: "parent" } },
				{ id: "agent", when: { parentClass: "local", agent: "reviewer" }, use: { kind: "declared" } },
			],
		});
		expect(parsed.ok).toBe(false);
		if (parsed.ok) return;
		expect(parsed.error.join("\n")).toContain("equal-specificity routing rules profile and agent");
	});

	it("rejects unknown fields, targets, and classes", () => {
		const parsed = parseModelRoutingPolicy({
			schemaVersion: 1,
			defaultClass: "cloud",
			modelClasses: { local: ["desktop-vllm/*"] },
			targets: {},
			rules: [{
				id: "bad",
				when: { parentClass: "nearby" },
				use: { kind: "named", target: "missing" },
			}],
			surprise: true,
		});
		expect(parsed.ok).toBe(false);
		if (parsed.ok) return;
		const errors = parsed.error.join("\n");
		expect(errors).toContain("policy contains unknown field surprise");
		expect(errors).toContain("unknown class nearby");
		expect(errors).toContain("unknown target missing");
	});
});

describe("model route resolution", () => {
	const declared = binding("openai-codex", "gpt-5.6-sol", "high");

	it("overrides a declared cloud profile with the exact active local binding", () => {
		const result = resolveModelRoute(
			parsePolicy(),
			{
				parent: binding("desktop-vllm", "deepseek-v4-flash", "max"),
				declared,
				workload: "subagent",
				profile: "general-review",
				agent: "code-reviewer",
			},
			"digest-1",
		);
		expect(result).toEqual({
			ok: true,
			value: {
				kind: "override",
				declared,
				effective: binding("desktop-vllm", "deepseek-v4-flash", "max"),
				parentClass: "local",
				ruleId: "local-parent",
				policyDigest: "digest-1",
			},
		});
	});

	it("preserves Loom's declared binding under cloud and unknown parents", () => {
		for (const parent of [
			binding("openai-codex", "gpt-5.6-sol", "high"),
			binding("future-provider", "future-model", "low"),
		]) {
			const result = resolveModelRoute(parsePolicy(), { parent, declared, workload: "subagent" }, "digest");
			expect(result.ok).toBe(true);
			if (!result.ok) continue;
			expect(result.value.kind).toBe("declared");
			expect(result.value.effective).toEqual(declared);
			expect(result.value.parentClass).toBe("cloud");
		}
	});

	it("preserves Pi's configured child default when no model was declared", () => {
		const result = resolveModelRoute(
			parsePolicy(),
			{ parent: binding("openai-codex", "gpt-5.6-sol", "high"), workload: "subagent", agent: "planner" },
			"digest",
		);
		expect(result).toEqual({
			ok: true,
			value: {
				kind: "declared",
				declared: undefined,
				effective: undefined,
				parentClass: "cloud",
				ruleId: undefined,
				policyDigest: "digest",
			},
		});
	});

	it("lets a more-specific agent rule preserve its declaration", () => {
		const policy = parsePolicy({
			rules: [
				{ id: "local-parent", when: { parentClass: "local" }, use: { kind: "parent" } },
				{
					id: "reviewer-declared",
					when: { parentClass: "local", workload: "subagent", agent: "code-reviewer" },
					use: { kind: "declared" },
				},
			],
		});
		const result = resolveModelRoute(
			policy,
			{
				parent: binding("desktop-vllm", "deepseek-v4-flash", "max"),
				declared,
				workload: "subagent",
				agent: "code-reviewer",
			},
			"digest",
		);
		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.value.kind).toBe("declared");
		expect(result.value.ruleId).toBe("reviewer-declared");
		expect(result.value.effective).toEqual(declared);
	});

	it("supports named exact targets for future workload-specific routing", () => {
		const policy = parsePolicy({
			rules: [{
				id: "cheap-scout",
				when: { parentClass: "local", workload: "subagent", profile: "scout" },
				use: { kind: "named", target: "fast" },
			}],
		});
		const result = resolveModelRoute(
			policy,
			{
				parent: binding("desktop-vllm", "deepseek-v4-flash", "max"),
				declared,
				workload: "subagent",
				profile: "scout",
			},
			"digest",
		);
		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.value.effective).toEqual(binding("openai-codex", "gpt-5.4-mini", "medium"));
	});
});

describe("served targets", () => {
	const declared = binding("openai-codex", "gpt-5.6-sol", "high");
	const servedPolicy = (target: Record<string, unknown> = { served: "desktop-vllm" }) =>
		parsePolicy({
			targets: { local: target },
			rules: [
				{ id: "local-children", when: { parentClass: "local" }, use: { kind: "named", target: "local" } },
				{ id: "cloud-children", when: { parentClass: "cloud" }, use: { kind: "named", target: "local" } },
			],
		});
	const served = (id: string) => {
		const model = parseModelReference(`desktop-vllm/${id}`);
		if (!model.ok) throw new Error(model.error);
		return { "desktop-vllm": model.value };
	};

	it("parses a served target and lists the providers the shell must probe", () => {
		const policy = servedPolicy({ served: "desktop-vllm", thinkingLevel: "high" });
		expect(policy.targets.local).toEqual({ kind: "served", provider: "desktop-vllm", thinkingLevel: "high" });
		expect(servedProviders(policy)).toEqual(["desktop-vllm"]);
		expect(servedProviders(parsePolicy())).toEqual([]);
	});

	it("rejects a target that names both an exact model and a served provider, or neither", () => {
		for (const target of [{ model: "desktop-vllm/x", served: "desktop-vllm" }, { thinkingLevel: "high" }, { served: "" }]) {
			const parsed = parseModelRoutingPolicy({
				schemaVersion: 1,
				defaultClass: "cloud",
				modelClasses: { local: ["desktop-vllm/*"] },
				targets: { local: target },
				rules: [],
			});
			expect(parsed.ok).toBe(false);
			if (parsed.ok) continue;
			expect(parsed.error.join("\n")).toContain("targets.local must name exactly one of model or served");
		}
	});

	it("routes a cloud parent's child to whatever model the provider serves now", () => {
		for (const id of ["glm-5.3-flash-hyperflare-tp2-v16", "warmind-1017-native"]) {
			const result = resolveModelRoute(
				servedPolicy({ served: "desktop-vllm", thinkingLevel: "high" }),
				{ parent: binding("openai-codex", "gpt-5.6-sol", "low"), declared, workload: "subagent", served: served(id) },
				"digest",
			);
			expect(result.ok).toBe(true);
			if (!result.ok) continue;
			expect(result.value.kind).toBe("override");
			expect(result.value.effective).toEqual(binding("desktop-vllm", id, "high"));
		}
	});

	it("follows the served model even when a local parent is pinned to the other one", () => {
		const result = resolveModelRoute(
			servedPolicy(),
			{
				parent: binding("desktop-vllm", "warmind-1017-native", "max"),
				declared,
				workload: "subagent",
				served: served("glm-5.3-flash-hyperflare-tp2-v16"),
			},
			"digest",
		);
		expect(result.ok).toBe(true);
		if (!result.ok) return;
		// No thinking level on the target: the parent's effort carries over.
		expect(result.value.effective).toEqual(binding("desktop-vllm", "glm-5.3-flash-hyperflare-tp2-v16", "max"));
	});

	it("fails closed when the shell could not tell what is served", () => {
		const result = resolveModelRoute(
			servedPolicy(),
			{ parent: binding("openai-codex", "gpt-5.6-sol", "high"), declared, workload: "subagent" },
			"digest",
		);
		expect(result).toEqual({
			ok: false,
			error: { kind: "served-model-unknown", ruleId: "cloud-children", provider: "desktop-vllm" },
		});
		if (result.ok) return;
		expect(routingErrorMessage(result.error)).toContain("desktop-vllm");
	});

	it("leaves exact targets independent of the served model", () => {
		const policy = parsePolicy({
			rules: [{ id: "fast", when: { parentClass: "cloud" }, use: { kind: "named", target: "fast" } }],
		});
		const result = resolveModelRoute(
			policy,
			{ parent: binding("openai-codex", "gpt-5.6-sol", "high"), workload: "subagent", served: served("anything") },
			"digest",
		);
		expect(result.ok).toBe(true);
		if (!result.ok) return;
		expect(result.value.effective).toEqual(binding("openai-codex", "gpt-5.4-mini", "medium"));
	});
});
