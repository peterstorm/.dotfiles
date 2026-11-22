/**
 * Test-only: Pi's own catalog (pi/models.json) as this extension's tests read it, so the ids they
 * classify and the model whose payload they check are the real ones. Pi loads an extension
 * directory's index.ts only, never this file.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Api, Model } from "@earendil-works/pi-ai";

export const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

type CatalogProvider = Readonly<{ api: unknown; models: readonly Readonly<Record<string, unknown>>[] }>;

/** The desktop-vllm provider of pi/models.json, parsed. */
function desktopVllm(): CatalogProvider {
	const raw: unknown = JSON.parse(readFileSync(join(import.meta.dir, "../../models.json"), "utf8"));
	const provider = isRecord(raw) && isRecord(raw.providers) ? raw.providers["desktop-vllm"] : undefined;
	const models: unknown = isRecord(provider) ? provider.models : undefined;
	if (!isRecord(provider) || !Array.isArray(models)) throw new Error("pi/models.json lists no desktop-vllm models");
	return { api: provider.api, models: models.filter(isRecord) };
}

/** Every model id the catalog lists under desktop-vllm: the ids the server can report. */
export const catalogIds = (): readonly string[] =>
	desktopVllm().models.flatMap((model) => (typeof model.id === "string" ? [model.id] : []));

/** The desktop-vllm entry for `id` (its compat decides the payload's shape), pointed at baseUrl. */
export function catalogModel(id: string, baseUrl: string): Model<Api> {
	const provider = desktopVllm();
	const entry = provider.models.find((model) => model.id === id);
	if (entry === undefined) throw new Error(`pi/models.json has no desktop-vllm/${id}`);
	return { ...entry, provider: "desktop-vllm", api: provider.api, baseUrl } as unknown as Model<Api>;
}
