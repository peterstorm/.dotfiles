// The ARTEX adapter over real HTTP: a Bun.serve stub with ARTEX's login and JWT check in
// front of the fake's handlers. Covers what artex.test.ts (the sync over a port fake)
// cannot: the request shapes, login, error bodies, and the credentials file.
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MANAGED_PROFILE, type ProfileId } from "./artex";
import {
	type ArtexRegistry,
	loadArtexCredentials,
	parseArtexCredentials,
	profileBody,
	shapeBody,
	syncArtexToPrimary,
} from "./artex-http";
import { desktopRow, type FakeArtex, FakeHttpError, fakeArtex } from "./artex.testkit";

const USER = "operator";
const PASSWORD = "s3cret-pass";
const TOKEN = "jwt-token";
const BASE = "http://192.168.0.80:8000/v1";

let dir = "";
let fake: FakeArtex;
let server: { port: number; stop: (force?: boolean) => void } | undefined;
/** Every request the stub saw: `METHOD path`. */
let requests: string[] = [];

/** ARTEX's routes for the sync, with its auth: login mints the token, everything else needs it. */
async function route(request: Request): Promise<Response> {
	const { pathname } = new URL(request.url);
	requests.push(`${request.method} ${pathname}`);
	const body: unknown = request.method === "GET" ? undefined : await request.json();
	try {
		if (request.method === "POST" && pathname === "/api/auth/login") {
			const ok = typeof body === "object" && body !== null && "username" in body && "password" in body && body.username === USER && body.password === PASSWORD;
			return ok ? Response.json({ token: TOKEN }) : Response.json({ error: "invalid username or password" }, { status: 401 });
		}
		if (request.headers.get("Authorization") !== `Bearer ${TOKEN}`) return Response.json({ error: "unauthorized" }, { status: 401 });
		const handlers: Readonly<Record<string, (b: unknown) => unknown>> = {
			"GET /api/llm/profiles": () => fake.listProfiles(),
			"GET /api/settings": () => fake.getSettings(),
			"POST /api/llm/profiles": (b) => fake.saveProfile(b),
			"POST /api/llm/profiles/active": (b) => fake.activate(b),
			"PUT /api/settings": (b) => fake.putSettings(b),
		};
		const handler = handlers[`${request.method} ${pathname}`];
		return handler ? Response.json(handler(body)) : Response.json({ error: "not found" }, { status: 404 });
	} catch (error) {
		if (error instanceof FakeHttpError) return Response.json({ error: error.message }, { status: error.status });
		throw error;
	}
}

const credentialsFile = (content: unknown, mode = 0o600): string => {
	const path = join(dir, "credentials.json");
	writeFileSync(path, typeof content === "string" ? content : JSON.stringify(content));
	chmodSync(path, mode);
	return path;
};

const goodCredentials = () => credentialsFile({ url: `http://127.0.0.1:${server?.port}/`, username: USER, password: PASSWORD });

const registry = (models: Readonly<Record<string, { baseUrl?: string; contextWindow?: number }>> = {}): ArtexRegistry => ({
	find: (provider, id) => (provider === "desktop-vllm" ? (models[id] ?? { baseUrl: BASE, contextWindow: 202_752 }) : undefined),
	getApiKeyForProvider: async () => "desktop-key",
});

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "artex-http-"));
	fake = fakeArtex({ rows: [desktopRow(3, "warmind-1017-native", "warmind-1017-native", { is_default: true })] });
	requests = [];
	server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: route });
});

afterEach(() => {
	server?.stop(true);
	rmSync(dir, { recursive: true, force: true });
});

describe("the credentials file", () => {
	it("parses url, username and password, and trims the url's trailing slash", () => {
		expect(parseArtexCredentials({ url: "https://artex.example/", username: "u", password: "p" })).toEqual({
			ok: true,
			value: { url: "https://artex.example", username: "u", password: "p" },
		});
		for (const raw of [null, { url: "ftp://x", username: "u", password: "p" }, { url: "https://x", username: "", password: "p" }, { url: "https://x", username: "u" }]) {
			const parsed = parseArtexCredentials(raw);
			expect(parsed.ok).toBe(false);
			if (!parsed.ok) expect(parsed.error).not.toContain("p\"");
		}
	});

	it("is absent, unusable or found, and never usable when others can read it", async () => {
		expect(await loadArtexCredentials(join(dir, "missing.json"))).toEqual({ kind: "absent" });
		expect(await loadArtexCredentials(credentialsFile("{not json"))).toEqual({ kind: "unusable", detail: `${join(dir, "credentials.json")} is not JSON` });
		const shared = await loadArtexCredentials(credentialsFile({ url: "https://x", username: "u", password: "p" }, 0o644));
		expect(shared.kind === "unusable" && shared.detail).toContain("readable by others; chmod 600");
		expect((await loadArtexCredentials(credentialsFile({ url: "https://x", username: "u", password: "p" }))).kind).toBe("found");
	});
});

describe("the request bodies", () => {
	const fields = { name: MANAGED_PROFILE, format: "openai", model: "m", baseUrl: BASE, contextWindowK: 202 };

	it("sends the key only when creating, and the id only when updating", () => {
		expect(profileBody({ kind: "create", fields, apiKey: "k" })).toEqual({
			name: MANAGED_PROFILE, format: "openai", model: "m", base_url: BASE, context_window_k: 202, streaming: true, api_key: "k",
		});
		const update = profileBody({ kind: "update", id: 4 as ProfileId, fields });
		expect(update).toMatchObject({ id: 4 });
		expect("api_key" in update).toBe(false);
	});

	it("turns the task limit on with the shape", () => {
		expect(shapeBody({ workers: 1, tasks: 1 })).toEqual({ workers: 1, task_concurrency_enabled: true, task_concurrency_limit: 1 });
	});
});

describe("syncing over HTTP", () => {
	it("logs in once, creates and activates the managed profile, and sets the shape", async () => {
		const sync = await syncArtexToPrimary("uncensored-native", "glm-5.3-uncensored-native", "apply", {
			registry: registry(),
			credentialsPath: goodCredentials(),
		});
		expect(sync).toMatchObject({ kind: "synced", target: { model: "glm-5.3-uncensored-native", contextWindowK: 202, shape: { workers: 1, tasks: 1 } } });
		expect(requests.filter((r) => r === "POST /api/auth/login")).toHaveLength(1);
		expect(fake.rows().find((row) => row.name === MANAGED_PROFILE)).toMatchObject({
			model: "glm-5.3-uncensored-native",
			context_window_k: 202,
			base_url: BASE,
			is_default: true,
			api_key: "desktop-key",
		});
		expect(fake.rows().find((row) => row.id === 3)?.is_default).toBe(false);
		expect(fake.settings()).toEqual({ workers: 1, task_concurrency_enabled: true, task_concurrency_limit: 1 });

		requests = [];
		const again = await syncArtexToPrimary("uncensored-native", "glm-5.3-uncensored-native", "apply", { registry: registry(), credentialsPath: goodCredentials() });
		expect(again).toMatchObject({ kind: "synced", changes: [] });
		expect(requests.filter((r) => !r.startsWith("GET ") && r !== "POST /api/auth/login")).toEqual([]);
	});

	it("follows the primary to a Flash engine: same profile, wider shape", async () => {
		const wiring = { registry: registry({ "deepseek-v4.1-flash-native": { baseUrl: BASE, contextWindow: 262_144 } }), credentialsPath: goodCredentials() };
		await syncArtexToPrimary("glm-native", "glm-5.3-native", "apply", { ...wiring, registry: registry() });
		const sync = await syncArtexToPrimary("deepseek", "deepseek-v4.1-flash-native", "apply", wiring);
		expect(sync).toMatchObject({ kind: "synced", target: { contextWindowK: 262, shape: { workers: 3, tasks: 1 } } });
		expect(fake.rows().filter((row) => row.name === MANAGED_PROFILE)).toHaveLength(1);
		expect(fake.rows().find((row) => row.name === MANAGED_PROFILE)?.model).toBe("deepseek-v4.1-flash-native");
		expect(fake.settings()).toMatchObject({ workers: 3, task_concurrency_limit: 1 });
	});

	it("checks without writing", async () => {
		const sync = await syncArtexToPrimary("glm", "glm-5.3-flash-hyperflare-tp2-v16", "check", { registry: registry(), credentialsPath: goodCredentials() });
		expect(sync.kind === "checked" && sync.drift.length).toBeGreaterThan(0);
		expect(fake.writes).toEqual([]);
	});

	it("reports a refused login without the password", async () => {
		const path = credentialsFile({ url: `http://127.0.0.1:${server?.port}`, username: USER, password: "wrong-pass" });
		const sync = await syncArtexToPrimary("glm", "glm-5.3-flash-hyperflare-tp2-v16", "apply", { registry: registry(), credentialsPath: path });
		expect(sync).toEqual({
			kind: "failed",
			error: { kind: "request", call: "read profiles", detail: "login refused (HTTP 401 from POST /api/auth/login: invalid username or password)" },
		});
		expect(JSON.stringify(sync)).not.toContain("wrong-pass");
		expect(fake.writes).toEqual([]);
	});

	it("carries ARTEX's own error text", async () => {
		const broken = { ...fake, putSettings: () => { throw new FakeHttpError(400, "concurrency limit must be > 0"); } };
		fake = broken;
		const sync = await syncArtexToPrimary("glm", "glm-5.3-flash-hyperflare-tp2-v16", "apply", { registry: registry(), credentialsPath: goodCredentials() });
		expect(sync).toEqual({
			kind: "failed",
			error: { kind: "request", call: "write settings", detail: "HTTP 400 from PUT /api/settings: concurrency limit must be > 0" },
		});
	});

	it("skips without credentials, and fails setup on what this machine lacks", async () => {
		expect(await syncArtexToPrimary("glm", "x", "apply", { registry: registry(), credentialsPath: join(dir, "none.json") })).toEqual({
			kind: "skipped",
			reason: `no ARTEX credentials at ${join(dir, "none.json")}`,
		});
		const missing = await syncArtexToPrimary("glm", "unknown-id", "apply", {
			registry: { ...registry(), find: () => undefined },
			credentialsPath: goodCredentials(),
		});
		expect(missing).toEqual({ kind: "failed", error: { kind: "setup", detail: "desktop-vllm/unknown-id has no baseUrl or contextWindow in pi/models.json" } });
		expect(requests).toEqual([]);
	});

	it("fails, not throws, when ARTEX is unreachable", async () => {
		const path = credentialsFile({ url: "http://127.0.0.1:1", username: USER, password: PASSWORD });
		const sync = await syncArtexToPrimary("glm", "glm-5.3-flash-hyperflare-tp2-v16", "apply", { registry: registry(), credentialsPath: path });
		expect(sync.kind === "failed" && sync.error.kind).toBe("request");
	});
});
