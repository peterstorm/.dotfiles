/**
 * glm-native-compaction: compact a session on GLM-5.3 full (ds4-native behind Maya) without
 * thinking.
 *
 * A `session_before_compact` hook. When the session's model is on desktop-vllm and the server
 * is serving GLM-5.3 full, it runs Pi's own compaction (`compact()`: the same prompts, cut point,
 * split-turn handling and failure checks) with thinking off, and asks Maya for no thinking on
 * every summary request (compaction.ts says why Pi's own "off" is not enough). Anything else, and
 * any failure, leaves the compaction to Pi exactly as before. PI_GLM_COMPACTION=off disables it.
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
	| Readonly<{ kind: "compacted"; compaction: CompactionResult }>
	| Readonly<{ kind: "aborted" }>
	| Readonly<{ kind: "fell-back"; error: string }>;

/** Everything the hook needs from outside, as plain functions so tests substitute fakes. */
export type CompactionPorts = Readonly<{
	enabled: () => boolean;
	/** The id desktop-vllm reports serving, or why that is unknown. Must not reject. */
	servedId: () => Promise<Result<string, string>>;
	/** Pi's compaction of this event, thinking off. Must not reject. */
	compactWithoutThinking: (event: SessionBeforeCompactEvent, model: Model<Api>) => Promise<Result<CompactionResult, string>>;
}>;

export async function compactOnGlmNative(
	event: SessionBeforeCompactEvent,
	model: Model<Api> | undefined,
	ports: CompactionPorts,
): Promise<CompactionOutcome> {
	if (!ports.enabled() || model?.provider !== PRIMARY_PROVIDER) return { kind: "pi-default" };
	const served = await ports.servedId();
	if (!served.ok || !servesGlmNative(served.value)) return { kind: "pi-default" };
	const compacted = await ports.compactWithoutThinking(event, model);
	if (compacted.ok) return { kind: "compacted", compaction: compacted.value };
	return event.signal.aborted ? { kind: "aborted" } : { kind: "fell-back", error: compacted.error };
}

/** The hook's answer to Pi: its own compaction (undefined), ours, or a cancel after an abort. */
export function resultOf(outcome: CompactionOutcome): SessionBeforeCompactResult | undefined {
	switch (outcome.kind) {
		case "compacted":
			return { compaction: outcome.compaction };
		case "aborted":
			return { cancel: true };
		case "pi-default":
		case "fell-back":
			return undefined;
		default:
			return assertNever(outcome);
	}
}

const assertNever = (value: never): never => {
	throw new Error(`unreachable: ${JSON.stringify(value)}`);
};

/** Pi's summary requests through pi-ai, each payload asking Maya for no thinking. */
export const streamWithoutThinking: StreamFn = (model, context, options) =>
	streamSimple(model, context, { ...options, onPayload: (payload) => withoutThinking(payload) });

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

export default function glmNativeCompactionExtension(pi: ExtensionAPI): void {
	pi.on("session_before_compact", async (event, ctx) => {
		const outcome = await compactOnGlmNative(event, ctx.model, {
			enabled: () => process.env.PI_GLM_COMPACTION !== "off",
			servedId: async () => {
				const probed = (await probeServedModels([PRIMARY_PROVIDER], servedModelSourceFromRegistry(ctx.modelRegistry)))[
					PRIMARY_PROVIDER
				];
				if (!probed) return { ok: false, error: `${PRIMARY_PROVIDER} was not probed` };
				return probed.ok ? { ok: true, value: probed.value.id } : probed;
			},
			compactWithoutThinking: compactWithoutThinkingVia(ctx.modelRegistry),
		});
		if (outcome.kind === "fell-back" && ctx.hasUI) {
			ctx.ui.notify(`GLM compaction without thinking failed (${outcome.error}); Pi compacts the usual way`, "warning");
		}
		return resultOf(outcome);
	});
}
