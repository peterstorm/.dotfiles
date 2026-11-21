/**
 * Compaction on GLM-5.3 full (ds4-native behind Maya) without thinking: the pure part.
 *
 * Pi compacts with the session's thinking level, `max` for these models, and Maya caps a
 * reply's thinking at 8,192 tokens. A compaction is one or two summary requests (two when the
 * cut falls inside a turn), so at ~6 tok/s most of it is thinking: on 2026-11-21 four
 * compactions wrote 10.6K-18.7K tokens each for summaries of 1.7K-6K, 30-50 minutes apiece.
 *
 * Pi's own "off" does not reach Maya: for these models Pi sends `thinking: {type: "disabled"}`
 * (the deepseek thinking format), which Maya's OpenAI path does not read, so the run config's
 * default effort applies. Maya does read `reasoning_effort: "none"`: the GLM template then
 * writes its `Low` header and a closed think block, and the summary is written directly.
 */

/**
 * GLM-5.3 full as ds4-native serves it: `glm-5.3-native` (stock), `glm-5.3-uncensored-native`,
 * `glm-5.3-cyber-native`. Hyperflare's GLM-5.3-Flash ids (`…-v16`, `…-uncensored`) and
 * WARMIND/DeepSeek (`warmind-1017-native`, `deepseek-…-native`) are not: Hyperflare has no
 * thinking off-switch, and the DeepSeek primaries are fast enough to think.
 */
const GLM_NATIVE = /^glm-.*native$/;

export const servesGlmNative = (servedId: string): boolean => GLM_NATIVE.test(servedId);

/** Maya's spelling of "no thinking" (serve/frontend.py EFFORT: none -> enable_thinking False). */
export const NO_THINKING = "none";

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * Request headers as a provider call takes them: a null value marks a header auth deletes, so it
 * is left out (agent-session.ts's withoutDeletedHeaders, which Pi does not export).
 */
export function withoutDeletedHeaders(
	headers: Readonly<Record<string, string | null>> | undefined,
): Record<string, string> | undefined {
	if (headers === undefined) return undefined;
	return Object.fromEntries(
		Object.entries(headers).flatMap(([name, value]) => (value === null ? [] : [[name, value] as const])),
	);
}

/**
 * A chat-completion payload asking Maya for no thinking, or undefined to leave anything else as
 * Pi built it. Never mutates its input.
 */
export function withoutThinking(payload: unknown): Record<string, unknown> | undefined {
	if (!isRecord(payload) || !Array.isArray(payload.messages)) return undefined;
	return { ...payload, reasoning_effort: NO_THINKING };
}
