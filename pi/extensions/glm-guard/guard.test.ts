import { describe, expect, it } from "bun:test";
import { guardPayload, profileFor, TUNED_BUDGETS, type GuardProfile } from "./guard";

const GLM_V16 = "glm-5.3-flash-hyperflare-tp2-v16";
const GLM_UNCENSORED = "glm-5.3-flash-hyperflare-tp2-uncensored";

const chat = (extra: Record<string, unknown> = {}): Record<string, unknown> => ({
	model: "warmind-1017-native",
	messages: [{ role: "user", content: "hi" }],
	max_tokens: 32768,
	stream: true,
	...extra,
});

const upstream = (): GuardProfile => {
	const profile = profileFor(GLM_V16);
	if (profile === undefined) throw new Error("expected a profile for GLM v16");
	return profile;
};
const tuned = (): GuardProfile => {
	const profile = profileFor(GLM_UNCENSORED);
	if (profile === undefined) throw new Error("expected a profile for the uncensored build");
	return profile;
};

describe("profileFor: what a served model gets", () => {
	it("leaves a model with an off switch alone", () => {
		for (const id of ["warmind-1017-native", "deepseek-v4.1-flash-native", "qwen3.8-27b", ""]) {
			expect(profileFor(id)).toBeUndefined();
		}
	});

	it("gives upstream GLM only the floor for a thinking-off request", () => {
		expect(profileFor(GLM_V16)).toEqual({ kind: "glm" });
		expect(profileFor("GLM-5.3-Flash")).toEqual({ kind: "glm" });
	});

	it("gives the tuned build clear_thinking and a reasoning budget as well", () => {
		expect(profileFor(GLM_UNCENSORED)).toEqual({ kind: "tuned-glm", budgets: TUNED_BUDGETS });
		expect(profileFor("GLM-5.3-Flash-UNCENSORED-NVFP4")).toEqual({ kind: "tuned-glm", budgets: TUNED_BUDGETS });
	});

	it("treats the retired CYBERSECURITY hybrids as upstream GLM: no catalog or primary serves them", () => {
		expect(profileFor("glm-5.3-flash-hyperflare-tp2-cyber-hybrid-bf16")).toEqual({ kind: "glm" });
	});

	it("keeps every budget positive and ordered by effort", () => {
		expect(TUNED_BUDGETS.low).toBeGreaterThan(0);
		expect(TUNED_BUDGETS.low).toBeLessThan(TUNED_BUDGETS.high);
		expect(TUNED_BUDGETS.high).toBeLessThan(TUNED_BUDGETS.max);
	});
});

describe("guardPayload: the thinking-off floor (every GLM)", () => {
	it("asks for the lowest effort when thinking is switched off, which GLM cannot honour", () => {
		const out = guardPayload(chat({ thinking: { type: "disabled" } }), upstream());
		expect(out?.reasoning_effort).toBe("low");
	});

	it("leaves an explicit effort alone", () => {
		expect(guardPayload(chat({ thinking: { type: "enabled" }, reasoning_effort: "max" }), upstream())).toBeUndefined();
		expect(guardPayload(chat({ thinking: { type: "disabled" }, reasoning_effort: "high" }), upstream())).toBeUndefined();
	});

	it("does nothing to a request that names no thinking mode at all", () => {
		expect(guardPayload(chat(), upstream())).toBeUndefined();
	});

	it("adds nothing else for upstream GLM: its preserved thinking is the intended mode", () => {
		const out = guardPayload(chat({ thinking: { type: "disabled" } }), upstream());
		expect(out).not.toHaveProperty("chat_template_kwargs");
		expect(out).not.toHaveProperty("thinking_token_budget");
	});
});

describe("guardPayload: the tuned build", () => {
	it("blanks earlier turns' reasoning in the prompt", () => {
		const out = guardPayload(chat({ thinking: { type: "enabled" }, reasoning_effort: "max" }), tuned());
		expect(out?.chat_template_kwargs).toEqual({ clear_thinking: true });
	});

	it("keeps the other template kwargs the request already carries", () => {
		const out = guardPayload(chat({ reasoning_effort: "high", chat_template_kwargs: { foo: 1 } }), tuned());
		expect(out?.chat_template_kwargs).toEqual({ foo: 1, clear_thinking: true });
	});

	it("respects an explicit clear_thinking, either way", () => {
		const off = guardPayload(chat({ reasoning_effort: "high", chat_template_kwargs: { clear_thinking: false } }), tuned());
		expect(off?.chat_template_kwargs).toEqual({ clear_thinking: false });
		expect(off?.thinking_token_budget).toBe(TUNED_BUDGETS.high);
	});

	it.each([
		["low", TUNED_BUDGETS.low],
		["high", TUNED_BUDGETS.high],
		["max", TUNED_BUDGETS.max],
	])("caps %s-effort reasoning at its budget", (effort, budget) => {
		expect(guardPayload(chat({ reasoning_effort: effort }), tuned())?.thinking_token_budget).toBe(budget);
	});

	it("caps like max when the effort is anything GLM reads as max", () => {
		expect(guardPayload(chat({ reasoning_effort: "xhigh" }), tuned())?.thinking_token_budget).toBe(TUNED_BUDGETS.max);
		expect(guardPayload(chat({ thinking: { type: "enabled" } }), tuned())?.thinking_token_budget).toBe(TUNED_BUDGETS.max);
	});

	it("caps a thinking-off request at the budget of the effort it was raised to", () => {
		const out = guardPayload(chat({ thinking: { type: "disabled" } }), tuned());
		expect(out?.reasoning_effort).toBe("low");
		expect(out?.thinking_token_budget).toBe(TUNED_BUDGETS.low);
	});

	it("never overrides a budget the request already sets, in either spelling", () => {
		expect(guardPayload(chat({ reasoning_effort: "max", thinking_token_budget: 500 }), tuned())?.thinking_token_budget).toBe(500);
		const anthropic = guardPayload(chat({ reasoning_effort: "max", thinking: { type: "enabled", budget_tokens: 900 } }), tuned());
		expect(anthropic).not.toHaveProperty("thinking_token_budget");
	});

	it("is idempotent: a payload already guarded needs no change", () => {
		const once = guardPayload(chat({ thinking: { type: "enabled" }, reasoning_effort: "max" }), tuned());
		expect(once).toBeDefined();
		expect(guardPayload(once, tuned())).toBeUndefined();
	});
});

describe("guardPayload: what it must never touch", () => {
	it("returns a copy and leaves the input unmodified", () => {
		const input = chat({ thinking: { type: "disabled" }, chat_template_kwargs: { a: 1 } });
		const snapshot = JSON.stringify(input);
		const out = guardPayload(input, tuned());
		expect(out).not.toBe(input);
		expect(JSON.stringify(input)).toBe(snapshot);
	});

	it("keeps every unrelated field byte for byte", () => {
		const input = chat({ thinking: { type: "disabled" }, tools: [{ type: "function" }], temperature: 0.7 });
		const out = guardPayload(input, tuned());
		expect(out).toMatchObject({ model: input.model, messages: input.messages, max_tokens: 32768, stream: true, tools: input.tools, temperature: 0.7 });
	});

	it.each([[null], [undefined], ["text"], [3], [[]], [{ model: "m" }], [{ model: "m", messages: "no" }]])(
		"ignores a payload that is not a chat completion: %p",
		(payload) => {
			expect(guardPayload(payload, tuned())).toBeUndefined();
		},
	);
});
