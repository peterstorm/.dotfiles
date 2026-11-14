import { parseModelReference, type ModelReference, type Result, type ServedModels } from "./policy.js";

/**
 * What a provider serves right now, for policy targets of the form
 * `{ "served": "<provider>" }`. The policy stays pure: this module probes once per
 * routing snapshot and hands the answer to resolveModelRoute as data.
 *
 * Port: the four capabilities the probe needs, so tests substitute plain fakes and
 * the adapter (servedModelSourceFromRegistry) is the only code touching the network.
 */
export type ServedModelSource = Readonly<{
	baseUrl: (provider: string) => string | undefined;
	apiKey: (provider: string) => Promise<string | undefined>;
	inCatalog: (provider: string, id: string) => boolean;
	/** GET url and return the parsed JSON body; throws on transport or HTTP failure. */
	fetchJson: (url: string, headers: Readonly<Record<string, string>>) => Promise<unknown>;
}>;

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

const describe = (error: unknown): string => (error instanceof Error ? error.message : String(error));

/** Parse an OpenAI `/v1/models` body into the single model it lists. */
export function servedModelId(body: unknown): Result<string, string> {
	const data = isRecord(body) ? body.data : undefined;
	if (!Array.isArray(data)) return { ok: false, error: "/models returned no data list" };
	const ids = data.flatMap((entry: unknown) => {
		const id = isRecord(entry) ? entry.id : undefined;
		return typeof id === "string" && id.trim() !== "" ? [id] : [];
	});
	if (ids.length !== 1 || data.length !== 1) {
		return { ok: false, error: `/models must list exactly one model, got ${data.length}` };
	}
	return { ok: true, value: ids[0] };
}

async function probeOne(provider: string, source: ServedModelSource): Promise<Result<ModelReference, string>> {
	try {
		const base = source.baseUrl(provider);
		if (!base) return { ok: false, error: `provider ${provider} has no baseUrl in Pi's catalog` };
		const key = await source.apiKey(provider);
		if (!key) return { ok: false, error: `no API key for provider ${provider}` };
		let body: unknown;
		try {
			body = await source.fetchJson(`${base.replace(/\/+$/, "")}/models`, { Authorization: `Bearer ${key}` });
		} catch (error) {
			return { ok: false, error: `cannot reach ${provider}: ${describe(error)}` };
		}
		const id = servedModelId(body);
		if (!id.ok) return id;
		if (!source.inCatalog(provider, id.value)) {
			return { ok: false, error: `${provider} serves ${id.value}, which is not in Pi's catalog` };
		}
		return parseModelReference(`${provider}/${id.value}`);
	} catch (error) {
		// A failing `!command` key, catalog lookup or similar: recorded, never thrown.
		return { ok: false, error: `cannot probe ${provider}: ${describe(error)}` };
	}
}

/** Probe each provider once, concurrently. Never throws: every failure is a Result in the map. */
export async function probeServedModels(
	providers: readonly string[],
	source: ServedModelSource,
): Promise<ServedModels> {
	const results = await Promise.all(providers.map(async (provider) => [provider, await probeOne(provider, source)] as const));
	return Object.freeze(Object.fromEntries(results));
}

type ProbeRegistry = Readonly<{
	getAll: () => ReadonlyArray<Readonly<{ provider: string; baseUrl?: string }>>;
	find: (provider: string, modelId: string) => unknown;
	getApiKeyForProvider: (provider: string) => Promise<string | undefined>;
}>;

/** Adapter: Pi's model registry (catalog, baseUrl, `!command` keys) plus fetch with a short timeout. */
export function servedModelSourceFromRegistry(registry: ProbeRegistry, timeoutMs: number = 4000): ServedModelSource {
	return Object.freeze({
		baseUrl: (provider: string) => registry.getAll().find((model) => model.provider === provider && model.baseUrl)?.baseUrl,
		apiKey: (provider: string) => registry.getApiKeyForProvider(provider),
		inCatalog: (provider: string, id: string) => registry.find(provider, id) !== undefined,
		fetchJson: async (url: string, headers: Readonly<Record<string, string>>) => {
			const response = await fetch(url, { headers: { ...headers }, signal: AbortSignal.timeout(timeoutMs) });
			if (!response.ok) throw new Error(`HTTP ${response.status} from ${url}`);
			const body: unknown = await response.json();
			return body;
		},
	});
}
