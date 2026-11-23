/**
 * A fake ARTEX for tests: the profile and settings handlers' semantics, in memory,
 * as ARTEX's Go server implements them (server_mgmt.go pgSaveProfile/pgActivateProfile,
 * server.go putSettings): lists send ids as strings, a save without `id` inserts, an
 * update without `api_key` keeps the stored key, activation clears every other
 * `is_default`, and settings take only the fields sent (workers must be above 0).
 *
 * Bodies go in and out as JSON values, so one fake backs both an ArtexPort (through
 * the adapter's own body builders) and the HTTP stub in artex-http.test.ts.
 */
import { type ArtexCall, type ArtexPort, isRecord } from "./artex";
import { profileBody, shapeBody } from "./artex-http";

export type FakeRow = Readonly<{
	id: number;
	name: string;
	format: string;
	base_url: string;
	model: string;
	context_window_k: number;
	is_default: boolean;
	api_key: string;
}>;

export type FakeSettings = Readonly<{ workers: number; task_concurrency_enabled: boolean; task_concurrency_limit: number }>;

export type FakeSeed = Readonly<{ rows?: readonly FakeRow[]; settings?: FakeSettings }>;

/** An HTTP-style failure the fake raises; the stub turns it into a status and `{ error }`. */
export class FakeHttpError extends Error {
	constructor(
		readonly status: number,
		message: string,
	) {
		super(message);
	}
}

const text = (value: unknown): string => (typeof value === "string" ? value : "");
const integer = (value: unknown): number => (typeof value === "number" && Number.isInteger(value) ? value : 0);

export function fakeArtex(seed: FakeSeed = {}) {
	let rows: FakeRow[] = [...(seed.rows ?? [])];
	let settings: FakeSettings = seed.settings ?? { workers: 3, task_concurrency_enabled: false, task_concurrency_limit: 5 };
	let nextId = Math.max(0, ...rows.map((row) => row.id)) + 1;
	/** Every accepted write, in order. */
	const writes: string[] = [];

	return {
		rows: (): readonly FakeRow[] => rows,
		settings: (): FakeSettings => settings,
		writes,
		listProfiles: (): unknown => ({
			profiles: rows.map(({ api_key, base_url, ...row }) => ({
				...row,
				id: String(row.id),
				...(base_url ? { base_url } : {}),
				...(api_key ? { api_key_hint: `…${api_key.slice(-4)}` } : {}),
				streaming: true,
			})),
		}),
		getSettings: (): unknown => ({ ...settings, llm_pool_enabled: false, llm_pool_bind_fallback: false }),
		saveProfile: (body: unknown): unknown => {
			if (!isRecord(body)) throw new FakeHttpError(400, "body is not an object");
			const fields = {
				name: text(body.name),
				format: text(body.format),
				base_url: text(body.base_url),
				model: text(body.model),
				context_window_k: integer(body.context_window_k),
			};
			const id = integer(body.id);
			if (id > 0) {
				const old = rows.find((row) => row.id === id);
				if (!old) throw new FakeHttpError(500, `sql: no rows (profile ${id})`);
				const api_key = text(body.api_key).trim() || old.api_key;
				rows = rows.map((row) => (row.id === id ? { ...row, ...fields, api_key } : row));
				writes.push(`update ${id}`);
				return { id };
			}
			const created = { id: nextId++, ...fields, is_default: false, api_key: text(body.api_key).trim() };
			rows = [...rows, created];
			writes.push(`create ${created.id}`);
			return { id: created.id };
		},
		activate: (body: unknown): unknown => {
			const id = isRecord(body) ? integer(body.id) : 0;
			if (!rows.some((row) => row.id === id)) throw new FakeHttpError(500, `profile ${id} not found`);
			rows = rows.map((row) => ({ ...row, is_default: row.id === id }));
			writes.push(`activate ${id}`);
			return { ok: true };
		},
		putSettings: (body: unknown): unknown => {
			if (!isRecord(body)) throw new FakeHttpError(400, "body is not an object");
			const { workers, task_concurrency_enabled: enabled, task_concurrency_limit: limit } = body;
			if (workers !== undefined && integer(workers) <= 0) throw new FakeHttpError(400, "workers must be > 0");
			if (limit !== undefined && integer(limit) <= 0) throw new FakeHttpError(400, "limit must be > 0");
			settings = {
				workers: workers === undefined ? settings.workers : integer(workers),
				task_concurrency_enabled: typeof enabled === "boolean" ? enabled : settings.task_concurrency_enabled,
				task_concurrency_limit: limit === undefined ? settings.task_concurrency_limit : integer(limit),
			};
			writes.push("settings");
			return { ok: true };
		},
	};
}

export type FakeArtex = ReturnType<typeof fakeArtex>;

/**
 * How one call misbehaves: `refuse` fails before the effect (ARTEX rejected it),
 * `lose-reply` fails after it (ARTEX applied it; the reply never arrived),
 * `ignore` reports success without applying it.
 */
export type Fault = Readonly<{ call: ArtexCall; how: "refuse" | "lose-reply" | "ignore" }>;

/** The fake as an ArtexPort, through the adapter's real body builders. Each fault fires once. */
export function fakeArtexPort(
	fake: FakeArtex,
	options: Readonly<{ faults?: readonly Fault[]; key?: () => Promise<string> }> = {},
): ArtexPort {
	const pending = [...(options.faults ?? [])];
	const run = async (call: ArtexCall, effect: () => unknown): Promise<unknown> => {
		const index = pending.findIndex((fault) => fault.call === call);
		const fault = index >= 0 ? pending.splice(index, 1)[0] : undefined;
		if (fault?.how === "refuse") throw new Error(`${call} refused`);
		if (fault?.how === "ignore") return call === "save profile" ? { id: 999 } : { ok: true };
		const reply = effect();
		if (fault?.how === "lose-reply") throw new Error(`${call}: connection reset`);
		return reply;
	};
	return Object.freeze({
		readProfiles: () => run("read profiles", fake.listProfiles),
		readSettings: () => run("read settings", fake.getSettings),
		saveProfile: (write) => run("save profile", () => fake.saveProfile(profileBody(write))),
		activateProfile: async (id) => {
			await run("activate profile", () => fake.activate({ id }));
		},
		writeShape: async (shape) => {
			await run("write settings", () => fake.putSettings(shapeBody(shape)));
		},
		newProfileKey: options.key ?? (async () => "desktop-key-6/M="),
	});
}

/** A row as ARTEX would hold it for a desktop profile. */
export const desktopRow = (
	id: number,
	name: string,
	model: string,
	extra: Partial<Omit<FakeRow, "id" | "name" | "model">> = {},
): FakeRow => ({
	id,
	name,
	format: "openai",
	base_url: "http://192.168.0.80:8000/v1",
	model,
	context_window_k: 256,
	is_default: false,
	api_key: "stored-key-6/M=",
	...extra,
});
