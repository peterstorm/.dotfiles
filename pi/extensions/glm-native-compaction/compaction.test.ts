import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { NO_THINKING, servesGlmNative, withoutDeletedHeaders, withoutThinking } from "./compaction";

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

/** Every model id Pi's catalog lists under desktop-vllm: the ids the server can report. */
const catalogIds = (): readonly string[] => {
	const raw: unknown = JSON.parse(readFileSync(join(import.meta.dir, "../../models.json"), "utf8"));
	const provider = isRecord(raw) && isRecord(raw.providers) ? raw.providers["desktop-vllm"] : undefined;
	const models: unknown = isRecord(provider) ? provider.models : undefined;
	if (!Array.isArray(models)) throw new Error("pi/models.json lists no desktop-vllm models");
	return models.flatMap((model: unknown) => (isRecord(model) && typeof model.id === "string" ? [model.id] : []));
};

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
				expect(out).toEqual({ ...payload, reasoning_effort: NO_THINKING });
				expect(out).not.toBe(payload);
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
	])("leaves %p as Pi built it", (payload) => {
		expect(withoutThinking(payload)).toBeUndefined();
	});
});
