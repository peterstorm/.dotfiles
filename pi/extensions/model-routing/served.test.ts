import { describe, expect, it } from "bun:test";
import { probeServedModels, servedModelId, type ServedModelSource } from "./served";

const modelsBody = (...ids: string[]) => ({ object: "list", data: ids.map((id) => ({ id, object: "model" })) });

const fakeSource = (overrides: Partial<ServedModelSource> = {}): ServedModelSource => ({
	baseUrl: (provider) => (provider === "desktop-vllm" ? "http://192.168.0.80:8000/v1" : undefined),
	apiKey: async () => "key",
	inCatalog: (provider, id) => provider === "desktop-vllm" && id !== "unlisted-model",
	fetchJson: async () => modelsBody("glm-5.3-flash-hyperflare-tp2-v16"),
	...overrides,
});

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
		expect(result.failures).toEqual({});
		expect(result.served["desktop-vllm"]?.id).toBe("warmind-1017-native");
		expect(result.served["desktop-vllm"]?.provider).toBe("desktop-vllm");
	});

	it("records why a provider could not be probed instead of guessing", async () => {
		const cases: ReadonlyArray<readonly [string, Partial<ServedModelSource>, string]> = [
			["unreachable", { fetchJson: async () => { throw new Error("connect ECONNREFUSED"); } }, "ECONNREFUSED"],
			["not in catalog", { fetchJson: async () => modelsBody("unlisted-model") }, "not in Pi's catalog"],
			["ambiguous", { fetchJson: async () => modelsBody("a", "b") }, "exactly one"],
			["no key", { apiKey: async () => undefined }, "no API key"],
		];
		for (const [name, overrides, reason] of cases) {
			const result = await probeServedModels(["desktop-vllm"], fakeSource(overrides));
			expect(result.served["desktop-vllm"]).toBeUndefined();
			expect(result.failures["desktop-vllm"] ?? `${name}: no failure`).toContain(reason);
		}
		const unknown = await probeServedModels(["nowhere"], fakeSource());
		expect(unknown.failures.nowhere).toContain("no baseUrl");
	});

	it("probes nothing when no rule needs a served model", async () => {
		let calls = 0;
		const result = await probeServedModels([], fakeSource({ fetchJson: async () => { calls++; return modelsBody("x"); } }));
		expect(calls).toBe(0);
		expect(result).toEqual({ served: {}, failures: {} });
	});
});
