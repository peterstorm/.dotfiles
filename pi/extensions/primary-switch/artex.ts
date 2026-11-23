/**
 * ARTEX follows the desktop primary.
 *
 * ARTEX (the agent platform on homelab's k8s) sends its LLM calls to whatever desktop
 * serves on :8000. After a `/switch` it must name the model that now serves, with that
 * model's context window, and run no more agents at once than the engine has Lanes.
 * GLM-5.3 full takes one request at a time and sets aside only ~42K tokens of other
 * conversations, so parallel agents re-read each other's prompts from scratch; the
 * Flash engines batch and want the parallelism.
 *
 * /switch owns one ARTEX profile, MANAGED_PROFILE, and points it at the primary; the
 * other profiles are the operator's and are never edited. The core here is pure (the
 * Lanes, the agent shape they allow, parsing ARTEX's replies, the plan from what ARTEX
 * has to what it should have); syncArtex is the one shell, every effect behind ArtexPort.
 */
import type { Result } from "../model-routing/policy.js";
import { errorMessage } from "../model-routing/served.js";
import type { Primary } from "./switch.js";

/** The engines the primaries run on. */
export type Engine = "hyperflare" | "ds4-native" | "glm53-native";

export const ENGINE_OF: Readonly<Record<Primary, Engine>> = Object.freeze({
	glm: "hyperflare",
	uncensored: "hyperflare",
	warmind: "ds4-native",
	deepseek: "ds4-native",
	"glm-native": "glm53-native",
	"uncensored-native": "glm53-native",
	"cyber-native": "glm53-native",
});

/**
 * Requests each engine decodes at once, as its launcher configures it, checked against
 * the launchers by artex.test.ts: Hyperflare's package has 8 slots and ds4-native runs
 * LANES=4 (both numbers read from the launcher), while the GLM-5.3 full launcher is
 * checked only for its one-request-at-a-time statement.
 */
export const ENGINE_LANES: Readonly<Record<Engine, number>> = Object.freeze({
	hyperflare: 8,
	"ds4-native": 4,
	"glm53-native": 1,
});

/**
 * How ARTEX spreads its LLM calls: each running task is one planner loop plus `workers`
 * worker loops, all calling the model, and at most `tasks` tasks run at once.
 */
export type AgentShape = Readonly<{ workers: number; tasks: number }>;

/** ARTEX's default workers per task: spare Lanes go to more tasks, not wider ones. */
export const MAX_WORKERS = 3;

/**
 * The widest shape whose callers, tasks × (planner + workers), fit in `lanes`. ARTEX's
 * narrowest shape is one task with one worker (two callers), so a single Lane gets that
 * and the engine queues the second caller.
 */
export function agentShapeFor(lanes: number): AgentShape {
	const workers = Math.min(MAX_WORKERS, Math.max(1, lanes - 1));
	return Object.freeze({ workers, tasks: Math.max(1, Math.floor(lanes / (1 + workers))) });
}

/** ARTEX counts context in K of 1,000 tokens; rounding down keeps it inside the served window. */
export const contextWindowK = (tokens: number): number => Math.floor(tokens / 1000);

/** What ARTEX should run: the served model, where, how big, and the shape its engine allows. */
export type ArtexTarget = Readonly<{ model: string; baseUrl: string; contextWindowK: number; shape: AgentShape }>;

/** The catalog entry for the served id (pi/models.json is the context window's source of truth). */
export type ServedModel = Readonly<{ id: string; baseUrl: string; contextWindow: number }>;

export const artexTarget = (primary: Primary, served: ServedModel): ArtexTarget =>
	Object.freeze({
		model: served.id,
		baseUrl: served.baseUrl,
		contextWindowK: contextWindowK(served.contextWindow),
		shape: agentShapeFor(ENGINE_LANES[ENGINE_OF[primary]]),
	});

/** The one profile /switch owns. Its name is also the sync's idempotency key. */
export const MANAGED_PROFILE = "desktop-primary";
/** ARTEX's name for an OpenAI-compatible endpoint, which every desktop engine is. */
export const PROFILE_FORMAT = "openai";

// --- what ARTEX reports, parsed ------------------------------------------------

export type ProfileId = number & { readonly __brand: "ProfileId" };

export type ArtexProfile = Readonly<{
	id: ProfileId;
	name: string;
	format: string;
	model: string;
	baseUrl: string;
	contextWindowK: number;
	/** ARTEX's `is_default`: the profile its engine runs on. */
	active: boolean;
}>;

/** The task concurrency switch and its limit as one state: a limit exists only while it is on. */
export type TaskLimit = Readonly<{ kind: "unlimited" }> | Readonly<{ kind: "limited"; tasks: number }>;

export type ArtexSettings = Readonly<{ workers: number; taskLimit: TaskLimit }>;

export type ArtexState = Readonly<{ profiles: readonly ArtexProfile[]; settings: ArtexSettings }>;

/** The ARTEX calls, named for errors. */
export type ArtexCall = "read profiles" | "read settings" | "save profile" | "activate profile" | "write settings";

export type ArtexError =
	/** This machine cannot sync: an unusable credentials file, a served id missing from Pi's catalog. */
	| Readonly<{ kind: "setup"; detail: string }>
	/** Transport, HTTP status or a refused login. */
	| Readonly<{ kind: "request"; call: ArtexCall; detail: string }>
	/** A reply that does not parse. */
	| Readonly<{ kind: "reply"; call: ArtexCall; detail: string }>
	/** More than one profile carries the managed name: which one /switch owns is unknowable. */
	| Readonly<{ kind: "ambiguous"; count: number }>
	/** Every write was accepted, yet ARTEX still differs from the target. */
	| Readonly<{ kind: "unsettled"; drift: readonly string[] }>;

/** The one object-shape guard for this module; the adapter, fake and tests import it. */
export const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

const isList = (value: unknown): value is readonly unknown[] => Array.isArray(value);

const ok = <T>(value: T): Result<T, never> => ({ ok: true, value });
const err = <E>(error: E): Result<never, E> => ({ ok: false, error });

const isCount = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

/** ARTEX sends int64 ids as decimal strings in lists and as numbers elsewhere. */
function parseProfileId(raw: unknown): ProfileId | undefined {
	const id = typeof raw === "string" && /^[1-9][0-9]*$/.test(raw) ? Number(raw) : raw;
	return isCount(id) && id > 0 ? (id as ProfileId) : undefined;
}

function parseProfile(raw: unknown, index: number): Result<ArtexProfile, string> {
	if (!isRecord(raw)) return err(`profile ${index} is not an object`);
	const id = parseProfileId(raw.id);
	if (id === undefined) return err(`profile ${index} has no valid id`);
	// ARTEX omits an empty base_url.
	const { name, format, model, base_url: baseUrl = "", context_window_k: k, is_default: active } = raw;
	if (typeof name !== "string" || typeof format !== "string" || typeof model !== "string" || typeof baseUrl !== "string") {
		return err(`profile ${id} lacks a name, format, model or base_url string`);
	}
	if (!isCount(k) || typeof active !== "boolean") return err(`profile ${id} lacks context_window_k or is_default`);
	return ok(Object.freeze({ id, name, format, model, baseUrl, contextWindowK: k, active }));
}

/** GET /api/llm/profiles: `{ profiles: [...] }`. */
export function parseProfiles(body: unknown): Result<readonly ArtexProfile[], string> {
	const list = isRecord(body) ? body.profiles : undefined;
	if (!isList(list)) return err("no profiles list");
	const parsed: ArtexProfile[] = [];
	for (const [index, raw] of list.entries()) {
		const profile = parseProfile(raw, index);
		if (!profile.ok) return profile;
		parsed.push(profile.value);
	}
	return ok(Object.freeze(parsed));
}

/** GET /api/settings: the three fields the agent shape lives in. */
export function parseSettings(body: unknown): Result<ArtexSettings, string> {
	if (!isRecord(body)) return err("settings are not an object");
	const { workers, task_concurrency_enabled: enabled, task_concurrency_limit: limit } = body;
	if (!isCount(workers) || workers < 1) return err("no positive workers count");
	if (typeof enabled !== "boolean" || !isCount(limit)) return err("no task_concurrency_enabled/limit");
	// ARTEX's SetConcurrency rejects a non-positive limit, so a running "limited" state cannot hold 0.
	if (enabled && limit < 1) return err("task_concurrency_limit must be positive when enabled");
	const taskLimit: TaskLimit = enabled ? { kind: "limited", tasks: limit } : { kind: "unlimited" };
	return ok(Object.freeze({ workers, taskLimit }));
}

/** POST /api/llm/profiles: `{ id }` of the saved profile. */
export function parseSavedId(body: unknown): Result<ProfileId, string> {
	const id = isRecord(body) ? parseProfileId(body.id) : undefined;
	return id === undefined ? err("no id for the saved profile") : ok(id);
}

// --- the plan --------------------------------------------------------------------

/** The managed profile's fields: all /switch sets (the rest stay ARTEX's defaults). */
export type ProfileFields = Readonly<{ name: string; format: string; model: string; baseUrl: string; contextWindowK: number }>;

/** A profile save: a new profile carries the API key; an update keeps the stored one. */
export type ProfileWrite =
	| Readonly<{ kind: "create"; fields: ProfileFields; apiKey: string }>
	| Readonly<{ kind: "update"; id: ProfileId; fields: ProfileFields }>;

export type ProfileStep =
	| Readonly<{ kind: "create" }>
	| Readonly<{ kind: "update"; id: ProfileId; activate: boolean }>
	| Readonly<{ kind: "keep"; id: ProfileId; activate: boolean }>;

/** What a sync does, and the same in words; `drift` is empty exactly when nothing is to be done. */
export type ArtexPlan = Readonly<{ profile: ProfileStep; writeShape: boolean; drift: readonly string[] }>;

export const profileFields = (target: ArtexTarget): ProfileFields =>
	Object.freeze({
		name: MANAGED_PROFILE,
		format: PROFILE_FORMAT,
		model: target.model,
		baseUrl: target.baseUrl,
		contextWindowK: target.contextWindowK,
	});

function profileDrift(current: ArtexProfile, want: ProfileFields): readonly string[] {
	const changed = (label: string, from: string, to: string) => (from === to ? [] : [`${label} ${from || "(none)"} → ${to}`]);
	return [
		...changed("model", current.model, want.model),
		...changed("context", `${current.contextWindowK}K`, `${want.contextWindowK}K`),
		...changed("base URL", current.baseUrl, want.baseUrl),
		...changed("format", current.format, want.format),
	];
}

const describeLimit = (limit: TaskLimit): string => (limit.kind === "limited" ? String(limit.tasks) : "unlimited");

function shapeDrift(settings: ArtexSettings, shape: AgentShape): readonly string[] {
	const tasksMatch = settings.taskLimit.kind === "limited" && settings.taskLimit.tasks === shape.tasks;
	return [
		...(settings.workers === shape.workers ? [] : [`workers ${settings.workers} → ${shape.workers}`]),
		...(tasksMatch ? [] : [`tasks at once ${describeLimit(settings.taskLimit)} → ${shape.tasks}`]),
	];
}

/** From what ARTEX has to the target. Pure and total; refuses only an ambiguous managed profile. */
export function planArtexSync(target: ArtexTarget, state: ArtexState): Result<ArtexPlan, ArtexError> {
	const managed = state.profiles.filter((profile) => profile.name === MANAGED_PROFILE);
	if (managed.length > 1) return err({ kind: "ambiguous", count: managed.length });
	const want = profileFields(target);
	const wasActive = state.profiles.find((profile) => profile.active)?.name ?? "none";
	const shape = shapeDrift(state.settings, target.shape);
	const current = managed[0];
	if (current === undefined) {
		return ok({
			profile: { kind: "create" },
			writeShape: shape.length > 0,
			drift: [`create ${MANAGED_PROFILE} (${want.model}, ${want.contextWindowK}K)`, `activate it (was ${wasActive})`, ...shape],
		});
	}
	const fields = profileDrift(current, want);
	const activate = !current.active;
	return ok({
		profile: { kind: fields.length > 0 ? "update" : "keep", id: current.id, activate },
		writeShape: shape.length > 0,
		drift: [
			...fields.map((change) => `${MANAGED_PROFILE} ${change}`),
			...(activate ? [`activate ${MANAGED_PROFILE} (was ${wasActive})`] : []),
			...shape,
		],
	});
}

// --- the shell -------------------------------------------------------------------

/**
 * ARTEX's HTTP API, one method per call. Reads return the body as received, for the
 * core to parse; every method throws on transport, HTTP or login failure.
 */
export type ArtexPort = Readonly<{
	readProfiles: () => Promise<unknown>;
	readSettings: () => Promise<unknown>;
	saveProfile: (write: ProfileWrite) => Promise<unknown>;
	activateProfile: (id: ProfileId) => Promise<void>;
	writeShape: (shape: AgentShape) => Promise<void>;
	/** The key a created profile gets: the desktop provider's. Throws when there is none. */
	newProfileKey: () => Promise<string>;
}>;

export type ArtexMode = "apply" | "check";

export type ArtexSync =
	/** Applied; `changes` is what it changed, empty when ARTEX was already on target. */
	| Readonly<{ kind: "synced"; target: ArtexTarget; changes: readonly string[] }>
	/** Read only; `drift` is what a sync would change. */
	| Readonly<{ kind: "checked"; target: ArtexTarget; drift: readonly string[] }>
	| Readonly<{ kind: "skipped"; reason: string }>
	| Readonly<{ kind: "failed"; error: ArtexError }>;

async function attempt<T>(call: ArtexCall, run: () => Promise<T>): Promise<Result<T, ArtexError>> {
	try {
		return ok(await run());
	} catch (error) {
		return err({ kind: "request", call, detail: errorMessage(error) });
	}
}

async function readState(port: ArtexPort): Promise<Result<ArtexState, ArtexError>> {
	const [profilesBody, settingsBody] = await Promise.all([
		attempt("read profiles", port.readProfiles),
		attempt("read settings", port.readSettings),
	]);
	if (!profilesBody.ok) return profilesBody;
	if (!settingsBody.ok) return settingsBody;
	const profiles = parseProfiles(profilesBody.value);
	if (!profiles.ok) return err({ kind: "reply", call: "read profiles", detail: profiles.error });
	const settings = parseSettings(settingsBody.value);
	if (!settings.ok) return err({ kind: "reply", call: "read settings", detail: settings.error });
	return ok({ profiles: profiles.value, settings: settings.value });
}

/** Save the managed profile as planned; resolves to its id and whether it still needs activating. */
async function applyProfile(
	step: ProfileStep,
	target: ArtexTarget,
	port: ArtexPort,
): Promise<Result<Readonly<{ id: ProfileId; activate: boolean }>, ArtexError>> {
	const fields = profileFields(target);
	switch (step.kind) {
		case "keep":
			return ok({ id: step.id, activate: step.activate });
		case "update": {
			const saved = await attempt("save profile", () => port.saveProfile({ kind: "update", id: step.id, fields }));
			return saved.ok ? ok({ id: step.id, activate: step.activate }) : saved;
		}
		case "create": {
			const saved = await attempt("save profile", async () =>
				port.saveProfile({ kind: "create", fields, apiKey: await port.newProfileKey() }),
			);
			if (!saved.ok) return saved;
			const id = parseSavedId(saved.value);
			return id.ok ? ok({ id: id.value, activate: true }) : err({ kind: "reply", call: "save profile", detail: id.error });
		}
		default:
			return assertNever(step);
	}
}

/**
 * Bring ARTEX onto the target (apply) or say how far it is (check). Idempotent: the
 * managed profile is found by name, so a second apply, or one after a lost reply,
 * converges instead of duplicating, and an apply with nothing to do writes nothing.
 * An apply re-reads ARTEX and fails as `unsettled` unless it now matches. Never throws.
 */
export async function syncArtex(target: ArtexTarget, port: ArtexPort, mode: ArtexMode): Promise<ArtexSync> {
	const failed = (error: ArtexError): ArtexSync => ({ kind: "failed", error });
	const before = await readState(port);
	if (!before.ok) return failed(before.error);
	const plan = planArtexSync(target, before.value);
	if (!plan.ok) return failed(plan.error);
	if (mode === "check") return { kind: "checked", target, drift: plan.value.drift };
	if (plan.value.drift.length === 0) return { kind: "synced", target, changes: [] };

	const profile = await applyProfile(plan.value.profile, target, port);
	if (!profile.ok) return failed(profile.error);
	if (profile.value.activate) {
		const activated = await attempt("activate profile", () => port.activateProfile(profile.value.id));
		if (!activated.ok) return failed(activated.error);
	}
	if (plan.value.writeShape) {
		const written = await attempt("write settings", () => port.writeShape(target.shape));
		if (!written.ok) return failed(written.error);
	}

	const after = await readState(port);
	if (!after.ok) return failed(after.error);
	const left = planArtexSync(target, after.value);
	if (!left.ok) return failed(left.error);
	if (left.value.drift.length > 0) return failed({ kind: "unsettled", drift: left.value.drift });
	return { kind: "synced", target, changes: plan.value.drift };
}

const assertNever = (value: never): never => {
	throw new Error(`unreachable: ${JSON.stringify(value)}`);
};

// --- words -----------------------------------------------------------------------

const plural = (count: number, noun: string): string => `${count} ${noun}${count === 1 ? "" : "s"}`;

const describeTarget = ({ model, contextWindowK: k, shape }: ArtexTarget): string =>
	`${model} (${k}K), ${plural(shape.workers, "worker")} a task, ${plural(shape.tasks, "task")} at once`;

export function describeArtexError(error: ArtexError): string {
	switch (error.kind) {
		case "setup":
			return error.detail;
		case "request":
			return `${error.call}: ${error.detail}`;
		case "reply":
			return `${error.call}: unexpected reply (${error.detail})`;
		case "ambiguous":
			return `${error.count} profiles are named ${MANAGED_PROFILE}; delete all but one in ARTEX`;
		case "unsettled":
			return `ARTEX accepted every write but still differs: ${error.drift.join("; ")}`;
		default:
			return assertNever(error);
	}
}

export function describeArtexSync(sync: ArtexSync): string {
	switch (sync.kind) {
		case "synced": {
			if (sync.changes.length === 0) return `ARTEX already on ${describeTarget(sync.target)}.`;
			// ARTEX reads the worker count when a task starts.
			const workersNote = sync.changes.some((change) => change.startsWith("workers ")) ? " Running tasks keep their workers." : "";
			return `ARTEX now on ${describeTarget(sync.target)} (${sync.changes.join("; ")}).${workersNote}`;
		}
		case "checked":
			return sync.drift.length === 0
				? `artex:      in sync: ${describeTarget(sync.target)}`
				: `artex:      out of sync; /switch to this primary would: ${sync.drift.join("; ")}`;
		case "skipped":
			return `ARTEX not synced: ${sync.reason}.`;
		case "failed":
			return `ARTEX sync failed: ${describeArtexError(sync.error)}`;
		default:
			return assertNever(sync);
	}
}
