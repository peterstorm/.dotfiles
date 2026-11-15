/**
 * glm-guard: keep a served GLM's thinking from running away.
 *
 * A `before_provider_request` hook. For a request to a model in desktop-vllm's catalog it asks the
 * server what it is actually serving (the primaries share one port and answer to any model id, so a
 * session pinned to WARMIND can be talking to the uncensored GLM) and, when that is a GLM, lets
 * guard.ts's profile rewrite the payload. Anything else passes through untouched.
 *
 * Fail-open by construction: Pi's runner keeps the original payload when a handler throws, the
 * probe is a Result (never a rejection), and PI_GLM_GUARD=off disables the hook outright.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { Result } from "../model-routing/policy.js";
import { errorMessage, probeServedModels, servedModelSourceFromRegistry } from "../model-routing/served.js";
import { PRIMARY_PROVIDER } from "../primary-switch/switch.js";
import { guardPayload, profileFor } from "./guard.js";

/** The server's answer changes only when a primary is switched; half a minute keeps it fresh and cheap. */
const SERVED_TTL_MS = 30_000;

/** Everything the hook needs from outside, as plain functions so tests substitute fakes. */
export type GuardPorts = Readonly<{
	enabled: () => boolean;
	/** Whether Pi's desktop-vllm catalog lists this model id (so cloud requests never match). */
	isLocalModel: (id: string) => boolean;
	/** The id the server reports serving, or why that is unknown. Must not reject. */
	servedId: () => Promise<Result<string, string>>;
}>;

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

/** The guarded payload, or undefined to leave the request exactly as Pi built it. */
export async function guardRequest(payload: unknown, ports: GuardPorts): Promise<Record<string, unknown> | undefined> {
	if (!ports.enabled()) return undefined;
	const model = isRecord(payload) && typeof payload.model === "string" ? payload.model : undefined;
	if (model === undefined || !ports.isLocalModel(model)) return undefined;
	const served = await ports.servedId();
	if (!served.ok) return undefined;
	const profile = profileFor(served.value);
	return profile === undefined ? undefined : guardPayload(payload, profile);
}

/**
 * One cached probe answer, failures included (a dead server then costs one probe per TTL, not one per
 * request), shared by concurrent callers. A throwing probe becomes a failed Result.
 */
export function servedIdCache(options: Readonly<{ ttlMs: number; now: () => number }>) {
	let entry: Readonly<{ at: number; result: Promise<Result<string, string>> }> | undefined;
	return {
		get(probe: () => Promise<Result<string, string>>): Promise<Result<string, string>> {
			if (entry !== undefined && options.now() - entry.at < options.ttlMs) return entry.result;
			const result = (async () => probe())().catch(
				(error: unknown): Result<string, string> => ({ ok: false, error: errorMessage(error) }),
			);
			entry = { at: options.now(), result };
			return result;
		},
	};
}

export default function glmGuardExtension(pi: ExtensionAPI): void {
	const served = servedIdCache({ ttlMs: SERVED_TTL_MS, now: Date.now });
	pi.on("before_provider_request", (event, ctx) =>
		guardRequest(event.payload, {
			enabled: () => process.env.PI_GLM_GUARD !== "off",
			isLocalModel: (id) => ctx.modelRegistry.find(PRIMARY_PROVIDER, id) !== undefined,
			servedId: () =>
				served.get(async () => {
					const probed = (await probeServedModels([PRIMARY_PROVIDER], servedModelSourceFromRegistry(ctx.modelRegistry)))[
						PRIMARY_PROVIDER
					];
					if (!probed) return { ok: false, error: `${PRIMARY_PROVIDER} was not probed` };
					return probed.ok ? { ok: true, value: probed.value.id } : probed;
				}),
		}),
	);
}
