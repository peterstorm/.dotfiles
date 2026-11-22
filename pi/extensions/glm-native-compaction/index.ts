/**
 * glm-native-compaction: compact a session on GLM-5.3 full (ds4-native behind Maya) without
 * thinking.
 *
 * A `session_before_compact` hook. When the session's model is on desktop-vllm and the server
 * is serving GLM-5.3 full, it runs Pi's own compaction (`compact()`: the same prompts, cut point,
 * split-turn handling and failure checks) with thinking off, and asks Maya for no thinking on
 * every summary request (compaction.ts says why Pi's own "off" is not enough). Anything else
 * leaves the compaction to Pi exactly as before. So does any failure, with a warning, except a
 * user abort, which cancels it. PI_GLM_COMPACTION=off disables it.
 *
 * The primaries share one port and answer to any model id, so the hook asks the server what it
 * serves rather than trusting the session's model id (as glm-guard does).
 */
import type { StreamFn } from "@earendil-works/pi-agent-core";
import type { Api, Model } from "@earendil-works/pi-ai";
import { streamSimple } from "@earendil-works/pi-ai/compat";
import {
	compact,
	type CompactionResult,
	type ExtensionAPI,
	type ExtensionHandler,
	type ModelRegistry,
	type SessionBeforeCompactEvent,
	type SessionBeforeCompactResult,
} from "@earendil-works/pi-coding-agent";
import type { Result } from "../model-routing/policy.js";
import { errorMessage, probeServedModels, servedModelSourceFromRegistry } from "../model-routing/served.js";
import { PRIMARY_PROVIDER } from "../primary-switch/switch.js";
import { servesGlmNative, withoutDeletedHeaders, withoutThinking } from "./compaction.js";

/** What became of one compaction. */
export type CompactionOutcome =
	| Readonly<{ kind: "pi-default" }>
	| Readonly<{ kind: "unprobed"; error: string }>
	| Readonly<{ kind: "compacted"; compaction: CompactionResult }>
	| Readonly<{ kind: "aborted" }>
	| Readonly<{ kind: "fell-back"; error: string }>;

/**
 * Everything the hook needs from outside, as plain functions so tests substitute fakes. Each
 * resolves to a Result; a port that rejects is a bug, which Pi's extension runner reports before
 * compacting its own way.
 */
export type CompactionPorts = Readonly<{
	enabled: () => boolean;
	/** The id desktop-vllm reports serving, or why that is unknown. */
	servedId: () => Promise<Result<string, string>>;
	/** Pi's compaction of this event, thinking off. */
	compactWithoutThinking: (event: SessionBeforeCompactEvent, model: Model<Api>) => Promise<Result<CompactionResult, string>>;
}>;

export async function compactOnGlmNative(
	event: SessionBeforeCompactEvent,
	model: Model<Api> | undefined,
	ports: CompactionPorts,
): Promise<CompactionOutcome> {
	if (!ports.enabled() || model?.provider !== PRIMARY_PROVIDER) return { kind: "pi-default" };
	const served = await ports.servedId();
	if (!served.ok) return { kind: "unprobed", error: served.error };
	if (!servesGlmNative(served.value)) return { kind: "pi-default" };
	const compacted = await ports.compactWithoutThinking(event, model);
	// Checked first: an abort mid-request makes compact() return an empty summary, not throw.
	if (event.signal.aborted) return { kind: "aborted" };
	return compacted.ok ? { kind: "compacted", compaction: compacted.value } : { kind: "fell-back", error: compacted.error };
}

/** The hook's answer to Pi: its own compaction (undefined), ours, or a cancel after an abort. */
export function resultOf(outcome: CompactionOutcome): SessionBeforeCompactResult | undefined {
	switch (outcome.kind) {
		case "compacted":
			return { compaction: outcome.compaction };
		case "aborted":
			return { cancel: true };
		case "pi-default":
		case "unprobed":
		case "fell-back":
			return undefined;
		default:
			return assertNever(outcome);
	}
}

/** What the user is told: why Pi is about to compact the slow way, or nothing. */
export function warningOf(outcome: CompactionOutcome): string | undefined {
	switch (outcome.kind) {
		case "unprobed":
			return `GLM compaction cannot tell what ${PRIMARY_PROVIDER} serves (${outcome.error}); Pi compacts the usual way, with thinking`;
		case "fell-back":
			return `GLM compaction without thinking failed (${outcome.error}); Pi compacts the usual way, with thinking`;
		case "pi-default":
		case "compacted":
		case "aborted":
			return undefined;
		default:
			return assertNever(outcome);
	}
}

const assertNever = (value: never): never => {
	throw new Error(`unreachable: ${JSON.stringify(value)}`);
};

/** The PI_GLM_COMPACTION switch: on unless set to "off". */
export const enabledIn = (env: Readonly<Record<string, string | undefined>>): boolean => env.PI_GLM_COMPACTION !== "off";

/**
 * pi-ai's payload hook for a summary request. pi-ai calls it inside the request's own error
 * handling, so throwing ends the request as an error: compact() fails and the user is warned,
 * rather than a request Maya would answer with thinking.
 */
export function payloadWithoutThinking(payload: unknown): Record<string, unknown> {
	const parsed = withoutThinking(payload);
	if (!parsed.ok) throw new Error(parsed.error);
	return parsed.value;
}

/** Pi's summary requests through pi-ai, each payload asking Maya for no thinking. */
export const streamWithoutThinking: StreamFn = (model, context, options) =>
	streamSimple(model, context, { ...options, onPayload: payloadWithoutThinking });

/** Adapter: the id desktop-vllm reports serving, through the shared served-model probe. */
export function servedIdVia(registry: ModelRegistry): CompactionPorts["servedId"] {
	return async () => {
		const probed = (await probeServedModels([PRIMARY_PROVIDER], servedModelSourceFromRegistry(registry)))[PRIMARY_PROVIDER];
		if (!probed) return { ok: false, error: `${PRIMARY_PROVIDER} was not probed` };
		return probed.ok ? { ok: true, value: probed.value.id } : probed;
	};
}

/** Adapter: Pi's compact() with the session's auth, thinking off, through streamWithoutThinking. */
export function compactWithoutThinkingVia(registry: ModelRegistry): CompactionPorts["compactWithoutThinking"] {
	return async (event, model) => {
		try {
			const auth = await registry.getApiKeyAndHeaders(model);
			if (!auth.ok) return { ok: false, error: auth.error };
			const requestModel = auth.baseUrl ? { ...model, baseUrl: auth.baseUrl } : model;
			const compaction = await compact(
				event.preparation,
				requestModel,
				auth.apiKey,
				withoutDeletedHeaders(auth.headers),
				event.customInstructions,
				event.signal,
				"off",
				streamWithoutThinking,
				auth.env,
			);
			return { ok: true, value: compaction };
		} catch (error) {
			return { ok: false, error: errorMessage(error) };
		}
	};
}

/** Where a warning goes when the session has no UI (print and RPC modes; stdout carries RPC). */
export type Stderr = (line: string) => void;

const consoleStderr: Stderr = (line) => console.error(line);

/** The hook itself: decide, warn when Pi is about to compact the slow way, answer Pi. */
export function compactionHook(
	env: Readonly<Record<string, string | undefined>>,
	stderr: Stderr = consoleStderr,
): ExtensionHandler<SessionBeforeCompactEvent, SessionBeforeCompactResult> {
	return async (event, ctx) => {
		const outcome = await compactOnGlmNative(event, ctx.model, {
			enabled: () => enabledIn(env),
			servedId: servedIdVia(ctx.modelRegistry),
			compactWithoutThinking: compactWithoutThinkingVia(ctx.modelRegistry),
		});
		const warning = warningOf(outcome);
		if (warning !== undefined) {
			if (ctx.hasUI) ctx.ui.notify(warning, "warning");
			else stderr(`glm-native-compaction: ${warning}`);
		}
		return resultOf(outcome);
	};
}

export default function glmNativeCompactionExtension(pi: ExtensionAPI): void {
	pi.on("session_before_compact", compactionHook(process.env));
}
