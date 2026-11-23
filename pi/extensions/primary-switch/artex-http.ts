/**
 * Adapter: ARTEX's HTTP API as an ArtexPort, the credentials it logs in with, and the
 * wiring from a /switch report to syncArtex.
 *
 * The credentials are a local file, never the repo: $PI_ARTEX_CREDENTIALS, else
 * ~/.config/artex/credentials.json, holding `{ "url", "username", "password" }` and
 * readable by its owner only. Without the file /switch leaves ARTEX alone, so a machine
 * that does not drive ARTEX (the work Mac) needs nothing.
 */
import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Result } from "../model-routing/policy.js";
import { errorMessage } from "../model-routing/served.js";
import {
	type AgentShape,
	type ArtexMode,
	type ArtexPort,
	type ArtexSync,
	artexTarget,
	isRecord,
	type ProfileWrite,
	syncArtex,
} from "./artex.js";
import { PRIMARY_PROVIDER, type Primary } from "./switch.js";

export type ArtexCredentials = Readonly<{ url: string; username: string; password: string }>;

/** The credentials file's content. The password never appears in an error. */
export function parseArtexCredentials(raw: unknown): Result<ArtexCredentials, string> {
	if (!isRecord(raw)) return { ok: false, error: "not a JSON object" };
	const { url, username, password } = raw;
	if (typeof url !== "string" || !/^https?:\/\/[^/\s]+/.test(url)) return { ok: false, error: "url must be an http(s) URL" };
	if (typeof username !== "string" || username === "") return { ok: false, error: "username must be a non-empty string" };
	if (typeof password !== "string" || password === "") return { ok: false, error: "password must be a non-empty string" };
	return { ok: true, value: Object.freeze({ url: url.replace(/\/+$/, ""), username, password }) };
}

export const defaultCredentialsPath = (): string =>
	process.env.PI_ARTEX_CREDENTIALS ?? join(homedir(), ".config/artex/credentials.json");

export type CredentialsLookup =
	| Readonly<{ kind: "absent" }>
	| Readonly<{ kind: "found"; credentials: ArtexCredentials }>
	| Readonly<{ kind: "unusable"; detail: string }>;

/** Read the credentials file. A missing file is `absent`, not an error; a file with group or other permission bits, unreadable, or invalid is `unusable`. */
export async function loadArtexCredentials(path: string): Promise<CredentialsLookup> {
	let text: string;
	try {
		if (((await stat(path)).mode & 0o077) !== 0) {
			return { kind: "unusable", detail: `${path} is readable by others; chmod 600 it` };
		}
		text = await readFile(path, "utf8");
	} catch (error) {
		if (isRecord(error) && error.code === "ENOENT") return { kind: "absent" };
		return { kind: "unusable", detail: `cannot read ${path}: ${errorMessage(error)}` };
	}
	let raw: unknown;
	try {
		raw = JSON.parse(text);
	} catch {
		return { kind: "unusable", detail: `${path} is not JSON` };
	}
	const parsed = parseArtexCredentials(raw);
	return parsed.ok ? { kind: "found", credentials: parsed.value } : { kind: "unusable", detail: `${path}: ${parsed.error}` };
}

/** POST /api/llm/profiles's body: an update names the id and omits the key, which ARTEX then keeps. */
export function profileBody(write: ProfileWrite): Readonly<Record<string, unknown>> {
	const { name, format, model, baseUrl, contextWindowK } = write.fields;
	const fields = { name, format, model, base_url: baseUrl, context_window_k: contextWindowK, streaming: true };
	return write.kind === "create" ? { ...fields, api_key: write.apiKey } : { ...fields, id: write.id };
}

/** PUT /api/settings's body: ARTEX leaves every field it is not sent as it is. */
export const shapeBody = ({ workers, tasks }: AgentShape): Readonly<Record<string, unknown>> => ({
	workers,
	task_concurrency_enabled: true,
	task_concurrency_limit: tasks,
});

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;

/** ARTEX's error replies are `{ "error": "…" }`; keep a short tail of anything else. */
async function failureOf(response: Response, what: string): Promise<Error> {
	const text = await response.text().catch(() => "");
	let detail = text.trim().slice(0, 200);
	try {
		const body: unknown = JSON.parse(text);
		if (isRecord(body) && typeof body.error === "string") detail = body.error;
	} catch {
		// not JSON: keep the text
	}
	return new Error(`HTTP ${response.status} from ${what}${detail ? `: ${detail}` : ""}`);
}

/**
 * The port over HTTP: logs in once (on the first call), then sends the JWT. One port
 * serves one sync. Throws on transport and HTTP failure, as the port requires.
 */
export function artexHttpPort(
	credentials: ArtexCredentials,
	newProfileKey: () => Promise<string>,
	fetchImpl: Fetch = fetch,
	timeoutMs: number = 10_000,
): ArtexPort {
	const send = async (method: string, path: string, body: unknown, token: string | undefined): Promise<unknown> => {
		const headers: Record<string, string> = { "Content-Type": "application/json" };
		if (token !== undefined) headers.Authorization = `Bearer ${token}`;
		const response = await fetchImpl(`${credentials.url}${path}`, {
			method,
			headers,
			body: body === undefined ? undefined : JSON.stringify(body),
			signal: AbortSignal.timeout(timeoutMs),
		});
		if (!response.ok) throw await failureOf(response, `${method} ${path}`);
		const text = await response.text();
		if (text.trim() === "") return undefined;
		const reply: unknown = JSON.parse(text);
		return reply;
	};
	let session: Promise<string> | undefined;
	const login = async (): Promise<string> => {
		const { username, password } = credentials;
		const reply = await send("POST", "/api/auth/login", { username, password }, undefined).catch((error: unknown) => {
			throw new Error(`login refused (${errorMessage(error)})`);
		});
		const token = isRecord(reply) ? reply.token : undefined;
		if (typeof token !== "string" || token === "") throw new Error("login replied without a token");
		return token;
	};
	const authed = async (method: string, path: string, body?: unknown): Promise<unknown> => {
		session ??= login();
		return send(method, path, body, await session);
	};
	return Object.freeze({
		readProfiles: () => authed("GET", "/api/llm/profiles"),
		readSettings: () => authed("GET", "/api/settings"),
		saveProfile: (write) => authed("POST", "/api/llm/profiles", profileBody(write)),
		activateProfile: async (id) => {
			await authed("POST", "/api/llm/profiles/active", { id });
		},
		writeShape: async (shape) => {
			await authed("PUT", "/api/settings", shapeBody(shape));
		},
		newProfileKey,
	});
}

/** The parts of Pi's model registry the sync reads. */
export type ArtexRegistry = Readonly<{
	find: (provider: string, id: string) => Readonly<{ baseUrl?: string; contextWindow?: number }> | undefined;
	getApiKeyForProvider: (provider: string) => Promise<string | undefined>;
}>;

export type ArtexWiring = Readonly<{ registry: ArtexRegistry; credentialsPath: string; fetchImpl?: Fetch }>;

/**
 * Sync ARTEX to a primary that serves `servedId`, or check how far it is. The served
 * model's base URL and context window come from Pi's catalog, the key a new profile
 * needs from the provider's. Never throws.
 */
export async function syncArtexToPrimary(
	primary: Primary,
	servedId: string,
	mode: ArtexMode,
	wiring: ArtexWiring,
): Promise<ArtexSync> {
	const setup = (detail: string): ArtexSync => ({ kind: "failed", error: { kind: "setup", detail } });
	try {
		const lookup = await loadArtexCredentials(wiring.credentialsPath);
		if (lookup.kind === "absent") return { kind: "skipped", reason: `no ARTEX credentials at ${wiring.credentialsPath}` };
		if (lookup.kind === "unusable") return setup(lookup.detail);
		const model = wiring.registry.find(PRIMARY_PROVIDER, servedId);
		if (!model?.baseUrl || !model.contextWindow) {
			return setup(`${PRIMARY_PROVIDER}/${servedId} has no baseUrl or contextWindow in pi/models.json`);
		}
		const newProfileKey = async (): Promise<string> => {
			const key = await wiring.registry.getApiKeyForProvider(PRIMARY_PROVIDER);
			if (!key) throw new Error(`no API key for ${PRIMARY_PROVIDER} to give the new profile`);
			return key;
		};
		const target = artexTarget(primary, { id: servedId, baseUrl: model.baseUrl, contextWindow: model.contextWindow });
		return await syncArtex(target, artexHttpPort(lookup.credentials, newProfileKey, wiring.fetchImpl), mode);
	} catch (error) {
		return setup(`cannot sync ARTEX: ${errorMessage(error)}`);
	}
}
