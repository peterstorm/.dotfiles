import { describe, expect, it } from "bun:test";
import { catalogIds } from "./catalog.testkit";
import { NO_THINKING, servesGlmNative, withoutDeletedHeaders, withoutThinking } from "./compaction";

const GLM_NATIVE_IDS = ["glm-5.3-native", "glm-5.3-uncensored-native", "glm-5.3-cyber-native"];

describe("servesGlmNative", () => {
	it("is true for exactly GLM-5.3 full's three served ids among the catalog's", () => {
		const ids = catalogIds();
		for (const id of GLM_NATIVE_IDS) expect(ids).toContain(id);
		expect(ids.filter(servesGlmNative).sort()).toEqual([...GLM_NATIVE_IDS].sort());
	});

	it.each([
		"glm-5.3-flash-hyperflare-tp2-v16",
		"glm-5.3-flash-hyperflare-tp2-uncensored",
		"warmind-1017-native",
		"deepseek-v4.1-flash-native",
		"",
		"native",
		"xglm-5.3-native",
		"glm-5.3-native-next",
	])("is false for %p", (id) => {
		expect(servesGlmNative(id)).toBe(false);
	});
});

describe("withoutDeletedHeaders", () => {
	it("drops exactly the headers auth marked for deletion", () => {
		expect(withoutDeletedHeaders({ "x-keep": "1", authorization: null, "x-also": "" })).toEqual({ "x-keep": "1", "x-also": "" });
		expect(withoutDeletedHeaders({ a: null })).toEqual({});
		expect(withoutDeletedHeaders({})).toEqual({});
		expect(withoutDeletedHeaders(undefined)).toBeUndefined();
	});
});

describe("withoutThinking", () => {
	const efforts = [undefined, "low", "high", "max", "none", 7];
	const thinkings = [undefined, { type: "enabled" }, { type: "disabled" }];

	it("asks for no thinking whatever effort and thinking field the request carried, keeping everything else", () => {
		for (const reasoning_effort of efforts) {
			for (const thinking of thinkings) {
				const payload = Object.freeze({
					model: "glm-5.3-uncensored-native",
					messages: Object.freeze([{ role: "user", content: "summarize" }]),
					max_tokens: 65536,
					stream: true,
					...(reasoning_effort === undefined ? {} : { reasoning_effort }),
					...(thinking === undefined ? {} : { thinking }),
				});
				const out = withoutThinking(payload);
				expect(out).toEqual({ ok: true, value: { ...payload, reasoning_effort: NO_THINKING } });
				if (out.ok) expect(out.value).not.toBe(payload);
			}
		}
	});

	it("never mutates its input", () => {
		const payload = { model: "m", messages: [], reasoning_effort: "max" };
		withoutThinking(payload);
		expect(payload).toEqual({ model: "m", messages: [], reasoning_effort: "max" });
	});

	// Each case wrapped in its own row: it.each spreads an array row into arguments.
	it.each<[unknown]>([
		[null],
		[undefined],
		["text"],
		[3],
		[[]],
		[[{ messages: [] }]],
		[{}],
		[{ messages: "not a list" }],
		[{ prompt: "legacy completion" }],
	])("refuses %p rather than letting it think", (payload) => {
		const out = withoutThinking(payload);
		expect(out.ok).toBe(false);
		if (!out.ok) expect(out.error).toContain("not a chat completion");
	});
});
