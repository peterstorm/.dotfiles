import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { TUNED_BUDGETS } from "./guard";
import glmGuardExtension, { guardRequest, servedIdCache, type GuardPorts } from "./index";

const GLM_V16 = "glm-5.3-flash-hyperflare-tp2-v16";
const GLM_UNCENSORED = "glm-5.3-flash-hyperflare-tp2-uncensored";
const WARMIND = "warmind-1017-native";

/** What Pi sends for a session pinned to WARMIND at max thinking. */
const pinnedToWarmind = (extra: Record<string, unknown> = {}): Record<string, unknown> => ({
	model: WARMIND,
	messages: [{ role: "user", content: "hi" }],
	thinking: { type: "enabled" },
	reasoning_effort: "max",
	...extra,
});

function ports(overrides: Partial<GuardPorts> & { served?: string | Error } = {}): GuardPorts {
	const { served = GLM_UNCENSORED, ...rest } = overrides;
	return {
		enabled: () => true,
		isLocalModel: (id) => id === WARMIND || id === GLM_V16 || id === GLM_UNCENSORED,
		servedId: async () => (served instanceof Error ? { ok: false, error: served.message } : { ok: true, value: served }),
		...rest,
	};
}

describe("guardRequest", () => {
	it("guards a session pinned to WARMIND when the server is actually serving the uncensored build", async () => {
		const out = await guardRequest(pinnedToWarmind(), ports({ served: GLM_UNCENSORED }));
		expect(out).toMatchObject({
			chat_template_kwargs: { clear_thinking: true },
			thinking_token_budget: TUNED_BUDGETS.max,
		});
	});

	it("leaves WARMIND's own requests exactly as they are", async () => {
		expect(await guardRequest(pinnedToWarmind(), ports({ served: WARMIND }))).toBeUndefined();
	});

	it("gives upstream GLM only the floor for a thinking-off request", async () => {
		const off = await guardRequest(pinnedToWarmind({ thinking: { type: "disabled" }, reasoning_effort: undefined }), ports({ served: GLM_V16 }));
		expect(off?.reasoning_effort).toBe("low");
		expect(await guardRequest(pinnedToWarmind(), ports({ served: GLM_V16 }))).toBeUndefined();
	});

	it("does nothing when the guard is switched off", async () => {
		expect(await guardRequest(pinnedToWarmind(), ports({ enabled: () => false }))).toBeUndefined();
	});

	it("does nothing for a model that is not a local one (a cloud request, a compaction summary)", async () => {
		expect(await guardRequest(pinnedToWarmind({ model: "gpt-5.4-mini" }), ports())).toBeUndefined();
	});

	it("does nothing when the served model cannot be read", async () => {
		expect(await guardRequest(pinnedToWarmind(), ports({ served: new Error("cannot reach desktop-vllm") }))).toBeUndefined();
	});

	it("does nothing for a payload with no model", async () => {
		expect(await guardRequest({ messages: [] }, ports())).toBeUndefined();
		expect(await guardRequest(null, ports())).toBeUndefined();
	});

	it("does not swallow a bug: a throwing port rejects, and Pi's runner reports it and keeps the payload", async () => {
		const exploding = ports({ servedId: async () => { throw new Error("boom"); } });
		await expect(guardRequest(pinnedToWarmind(), exploding)).rejects.toThrow("boom");
	});
});

describe("servedIdCache", () => {
	it("probes once within the TTL and again after it", async () => {
		let now = 1_000;
		let probes = 0;
		const cache = servedIdCache({ ttlMs: 30_000, now: () => now });
		const probe = async () => { probes++; return { ok: true as const, value: GLM_UNCENSORED }; };
		await cache.get(probe);
		now += 29_000;
		await cache.get(probe);
		expect(probes).toBe(1);
		now += 2_000;
		await cache.get(probe);
		expect(probes).toBe(2);
	});

	it("caches a failure too, so a dead server costs one probe per TTL rather than one per request", async () => {
		let probes = 0;
		const cache = servedIdCache({ ttlMs: 30_000, now: () => 0 });
		const probe = async () => { probes++; return { ok: false as const, error: "cannot reach" }; };
		expect(await cache.get(probe)).toEqual({ ok: false, error: "cannot reach" });
		await cache.get(probe);
		expect(probes).toBe(1);
	});

	it("shares one probe between concurrent requests", async () => {
		let probes = 0;
		let release: (() => void) | undefined;
		const gate = new Promise<void>((resolve) => { release = resolve; });
		const cache = servedIdCache({ ttlMs: 30_000, now: () => 0 });
		const probe = async () => { probes++; await gate; return { ok: true as const, value: WARMIND }; };
		const pending = [cache.get(probe), cache.get(probe), cache.get(probe)];
		release?.();
		const results = await Promise.all(pending);
		expect(probes).toBe(1);
		expect(results.every((result) => result.ok && result.value === WARMIND)).toBe(true);
	});

	it("turns a throwing probe into a failed result instead of rejecting", async () => {
		const cache = servedIdCache({ ttlMs: 30_000, now: () => 0 });
		const result = await cache.get(async () => { throw new Error("socket hang up"); });
		expect(result).toEqual({ ok: false, error: "socket hang up" });
	});
});

describe("the registered hook", () => {
	let server: { port: number; stop: (force?: boolean) => void } | undefined;
	let served = GLM_UNCENSORED;

	beforeEach(() => {
		served = GLM_UNCENSORED;
		server = Bun.serve({
			port: 0,
			hostname: "127.0.0.1",
			fetch: () => Response.json({ object: "list", data: [{ id: served, object: "model" }] }),
		});
	});
	afterEach(() => {
		server?.stop(true);
		delete process.env.PI_GLM_GUARD;
	});

	type Handler = (event: { type: string; payload: unknown }, ctx: ExtensionContext) => Promise<unknown>;

	/** Register against a stub Pi API; desktop-vllm's catalog is the three ids and /models is the live stub. */
	function registered(): Handler {
		let handler: Handler | undefined;
		const pi = {
			on: (event: string, h: Handler) => {
				if (event === "before_provider_request") handler = h;
				return () => {};
			},
		} as unknown as ExtensionAPI;
		glmGuardExtension(pi);
		if (!handler) throw new Error("the extension registered no before_provider_request handler");
		return handler;
	}

	const ctx = (): ExtensionContext => {
		const catalog = new Set([WARMIND, GLM_V16, GLM_UNCENSORED]);
		return {
			modelRegistry: {
				getAll: () => [{ provider: "desktop-vllm", baseUrl: `http://127.0.0.1:${server?.port}/v1` }],
				find: (provider: string, id: string) => (provider === "desktop-vllm" && catalog.has(id) ? { provider, id } : undefined),
				getApiKeyForProvider: async () => "key",
			},
		} as unknown as ExtensionContext;
	};

	it("registers exactly one before_provider_request handler", () => {
		expect(typeof registered()).toBe("function");
	});

	it("guards a request to the uncensored build, probing the live /v1/models", async () => {
		const out = await registered()({ type: "before_provider_request", payload: pinnedToWarmind() }, ctx());
		expect(out).toMatchObject({ chat_template_kwargs: { clear_thinking: true }, thinking_token_budget: TUNED_BUDGETS.max });
	});

	it("leaves a request alone when WARMIND is what the server serves", async () => {
		served = WARMIND;
		expect(await registered()({ type: "before_provider_request", payload: pinnedToWarmind() }, ctx())).toBeUndefined();
	});

	it("is switched off by PI_GLM_GUARD=off", async () => {
		process.env.PI_GLM_GUARD = "off";
		expect(await registered()({ type: "before_provider_request", payload: pinnedToWarmind() }, ctx())).toBeUndefined();
	});

	it("leaves the payload alone when the server is unreachable", async () => {
		server?.stop(true);
		expect(await registered()({ type: "before_provider_request", payload: pinnedToWarmind() }, ctx())).toBeUndefined();
	});
});
