/**
 * What a request to a served GLM needs so its thinking cannot run away.
 *
 * GLM served by Hyperflare has no thinking off-switch: it ignores `thinking: disabled`
 * and a missing `reasoning_effort` means max. On top of that, the chat template's
 * default (`clear_thinking = false`) replays every earlier turn's reasoning into each
 * new prompt. A model that thinks long (dealignai's CYBERSECURITY tune thinks about
 * twice as long as upstream) then fills its own context with its old reasoning —
 * measured in a real session at 60% of the prompt — and degenerates into a
 * fixed-point attractor (`their-ih-ih-ih-…`). The tune's own card names this and ships
 * `clear_thinking = true`; the package here cannot (its template is hash-pinned by the
 * exporter), so the request carries it.
 *
 * Pure: the profile follows from the id the server reports serving, and the payload is
 * returned as a new value. index.ts holds the shell (hook, probe, cache).
 */

export type Effort = "low" | "high" | "max";
export type ThinkingBudgets = Readonly<Record<Effort, number>>;

/**
 * Reasoning-token caps by effort for the tuned build. Calibrated on 1,468 real thinking blocks from local
 * GLM/WARMIND sessions: healthy blocks have p95 ≈ 2.2K tokens and p99 ≈ 5K, so `max` at 8K leaves every
 * ordinary block untouched while a runaway is cut after ~30 s of decode. Measured on the live server: at
 * budget exhaustion Hyperflare closes the thinking and the model goes on to answer (it does not truncate
 * the turn), and it accepts the field for GLM. A cap bounds a spiral; it does not prevent one.
 */
export const TUNED_BUDGETS: ThinkingBudgets = Object.freeze({ low: 2_048, high: 4_096, max: 8_192 });

/**
 * How a served GLM is guarded. `glm` is any upstream build (its preserved thinking is the intended mode,
 * so it only gets the thinking-off floor); `tuned-glm` is a tuned build that also gets clear_thinking and a budget.
 */
export type GuardProfile =
	| Readonly<{ kind: "glm" }>
	| Readonly<{ kind: "tuned-glm"; budgets: ThinkingBudgets }>;

const GLM_FAMILY = /^glm/i;
const TUNED_BUILD = /cyber/i;

/** The guard for a served model id, or undefined when its template has an off switch of its own. */
export function profileFor(servedId: string): GuardProfile | undefined {
	if (!GLM_FAMILY.test(servedId)) return undefined;
	return TUNED_BUILD.test(servedId) ? { kind: "tuned-glm", budgets: TUNED_BUDGETS } : { kind: "glm" };
}

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

/** The effort GLM will actually use: only low and high are read, anything else (or nothing) is max. */
const effectiveEffort = (value: unknown): Effort => (value === "low" || value === "high" ? value : "max");

/** An Anthropic-style budget (`thinking.budget_tokens`) already bounds the request. */
const bindsBudget = (thinking: unknown): boolean => isRecord(thinking) && thinking.budget_tokens !== undefined;

/**
 * The payload with the profile's guards applied, or undefined when nothing needs changing
 * (not a chat completion, or already guarded). Never mutates its input; never overrides a
 * value the request set itself.
 */
export function guardPayload(payload: unknown, profile: GuardProfile): Record<string, unknown> | undefined {
	if (!isRecord(payload) || !Array.isArray(payload.messages)) return undefined;
	const guarded: Record<string, unknown> = { ...payload };
	let changed = false;

	// Floor: GLM cannot be told to skip thinking, and an effortless request is max.
	// A request that asks for no thinking gets the lowest effort instead.
	const thinkingOff = isRecord(payload.thinking) && payload.thinking.type === "disabled";
	if (thinkingOff && payload.reasoning_effort === undefined) {
		guarded.reasoning_effort = "low";
		changed = true;
	}

	if (profile.kind === "tuned-glm") {
		const kwargs = isRecord(payload.chat_template_kwargs) ? payload.chat_template_kwargs : {};
		if (kwargs.clear_thinking === undefined) {
			guarded.chat_template_kwargs = { ...kwargs, clear_thinking: true };
			changed = true;
		}
		if (payload.thinking_token_budget === undefined && !bindsBudget(payload.thinking)) {
			guarded.thinking_token_budget = profile.budgets[effectiveEffort(guarded.reasoning_effort)];
			changed = true;
		}
	}

	return changed ? guarded : undefined;
}
