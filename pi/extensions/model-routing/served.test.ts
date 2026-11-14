import { afterEach, describe, expect, it } from "bun:test";
import { probeServedModels, servedModelId, servedModelSourceFromRegistry, type ServedModelSource } from "./served";

const modelsBody = (...ids: string[]) => ({ object: "list", data: ids.map((id) => ({ id, object: "model" })) });

const fakeSource = (overrides: Partial<ServedModelSource> = {}): ServedModelSource => ({
	baseUrl: (provider) => (provider === "desktop-vllm" ? "http://192.168.0.80:8000/v1" : undefined),
	apiKey: async () => "key",
	inCatalog: (provider, id) => provider === "desktop-vllm" && id !== "unlisted-model",
	fetchJson: async () => modelsBody("glm-5.3-flash-hyperflare-tp2-v16"),
	...overrides,
});

const failureOf = (result: Awaited<ReturnType<typeof probeServedModels>>, provider: string): string => {
	const entry = result[provider];
	if (!entry) return `${provider}: not probed`;
	return entry.ok ? `${provider}: unexpectedly served ${entry.value.id}` : entry.error;
};

describe("served model id", () => {
	it("reads the one model an OpenAI /v1/models list names", () => {
		expect(servedModelId(modelsBody("warmind-1017-native"))).toEqual({ ok: true, value: "warmind-1017-native" });
	});

	it("refuses lists that do not name exactly one model", () => {
		for (const body of [modelsBody(), modelsBody("a", "b"), { data: [{ id: "" }] }, { data: "x" }, [], null, "text"]) {
			expect(servedModelId(body).ok).toBe(false);
		}
	});
});

describe("probing served models", () => {
	it("maps each provider to the catalog model it serves", async () => {
		let requested: Readonly<{ url: string; auth?: string }> | undefined;
		const result = await probeServedModels(["desktop-vllm"], fakeSource({
			fetchJson: async (url, headers) => {
				requested = { url, auth: headers.Authorization };
				return modelsBody("warmind-1017-native");
			},
		}));
		expect(requested).toEqual({ url: "http://192.168.0.80:8000/v1/models", auth: "Bearer key" });
		const entry = result["desktop-vllm"];
		expect(entry?.ok).toBe(true);
		if (!entry?.ok) return;
		expect(entry.value.id).toBe("warmind-1017-native");
		expect(entry.value.provider).toBe("desktop-vllm");
	});

	it("records why a provider could not be probed instead of guessing", async () => {
		const cases: ReadonlyArray<readonly [Partial<ServedModelSource>, string]> = [
			[{ fetchJson: async () => { throw new Error("connect ECONNREFUSED"); } }, "ECONNREFUSED"],
			[{ fetchJson: async () => modelsBody("unlisted-model") }, "not in Pi's catalog"],
			[{ fetchJson: async () => modelsBody("a", "b") }, "exactly one"],
			[{ apiKey: async () => undefined }, "no API key"],
		];
		for (const [overrides, reason] of cases) {
			expect(failureOf(await probeServedModels(["desktop-vllm"], fakeSource(overrides)), "desktop-vllm")).toContain(reason);
		}
		expect(failureOf(await probeServedModels(["nowhere"], fakeSource()), "nowhere")).toContain("no baseUrl");
	});

	it("never throws: a rejecting key command or catalog lookup is a recorded failure", async () => {
		const keyFails = await probeServedModels(["desktop-vllm"], fakeSource({
			apiKey: async () => { throw new Error("ssh: connect to host desktop: timed out"); },
		}));
		expect(failureOf(keyFails, "desktop-vllm")).toContain("timed out");
		const catalogFails = await probeServedModels(["desktop-vllm"], fakeSource({
			inCatalog: () => { throw new Error("catalog unavailable"); },
		}));
		expect(failureOf(catalogFails, "desktop-vllm")).toContain("catalog unavailable");
	});

	it("probes nothing when no provider is needed", async () => {
		let calls = 0;
		const result = await probeServedModels([], fakeSource({ fetchJson: async () => { calls++; return modelsBody("x"); } }));
		expect(calls).toBe(0);
		expect(result).toEqual({});
	});
});

describe("registry adapter against a live HTTP stub", () => {
	const servers: Array<{ stop: (force?: boolean) => void }> = [];
	afterEach(() => {
		for (const server of servers.splice(0)) server.stop(true);
	});

	const serve = (handler: (request: Request) => Response | Promise<Response>) => {
		const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: handler });
		servers.push(server);
		return `http://127.0.0.1:${server.port}/v1`;
	};

	const registry = (baseUrl: string, catalog: readonly string[] = ["glm-5.3-flash-hyperflare-tp2-v16"]) => ({
		getAll: () => [{ provider: "cloud" }, { provider: "desktop-vllm", baseUrl }],
		find: (provider: string, id: string) => (provider === "desktop-vllm" && catalog.includes(id) ? { id } : undefined),
		getApiKeyForProvider: async (provider: string) => (provider === "desktop-vllm" ? "sekrit" : undefined),
	});

	it("sends the key, finds the provider's baseUrl, and maps the served model", async () => {
		let auth: string | null = null;
		const base = serve((request) => {
			auth = request.headers.get("authorization");
			return Response.json(modelsBody("glm-5.3-flash-hyperflare-tp2-v16"));
		});
		const result = await probeServedModels(["desktop-vllm"], servedModelSourceFromRegistry(registry(base)));
		expect(auth).toBe("Bearer sekrit");
		expect(result["desktop-vllm"]).toEqual({
			ok: true,
			value: expect.objectContaining({ provider: "desktop-vllm", id: "glm-5.3-flash-hyperflare-tp2-v16" }),
		});
	});

	it("turns an HTTP error into a recorded failure", async () => {
		const base = serve(() => new Response("nope", { status: 500 }));
		const result = await probeServedModels(["desktop-vllm"], servedModelSourceFromRegistry(registry(base)));
		expect(failureOf(result, "desktop-vllm")).toContain("HTTP 500");
	});

	it("gives up on a stalled server within the timeout", async () => {
		const base = serve(() => new Promise<Response>(() => {}));
		const started = Date.now();
		const result = await probeServedModels(["desktop-vllm"], servedModelSourceFromRegistry(registry(base), 150));
		expect(Date.now() - started).toBeLessThan(2000);
		expect(failureOf(result, "desktop-vllm")).toContain("cannot reach desktop-vllm");
	});

	it("refuses a served model that is missing from Pi's catalog", async () => {
		const base = serve(() => Response.json(modelsBody("something-else")));
		const result = await probeServedModels(["desktop-vllm"], servedModelSourceFromRegistry(registry(base)));
		expect(failureOf(result, "desktop-vllm")).toContain("not in Pi's catalog");
	});
});
