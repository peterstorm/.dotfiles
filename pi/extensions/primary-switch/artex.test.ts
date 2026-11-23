import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
	agentShapeFor,
	type ArtexCall,
	type ArtexPort,
	type ArtexProfile,
	type ArtexSync,
	type ArtexTarget,
	artexTarget,
	contextWindowK,
	describeArtexSync,
	type Engine,
	isRecord,
	ENGINE_LANES,
	ENGINE_OF,
	MANAGED_PROFILE,
	MAX_WORKERS,
	parseProfiles,
	parseSavedId,
	parseSettings,
	planArtexSync,
	type ProfileId,
	profileFields,
	syncArtex,
} from "./artex";
import { profileBody } from "./artex-http";
import { desktopRow, type FakeRow, type FakeSettings, fakeArtex, fakeArtexPort } from "./artex.testkit";
import { PRIMARIES, PRIMARY_PROVIDER, type Primary } from "./switch";

const REPO = join(import.meta.dir, "../../..");
const read = (path: string): string => readFileSync(join(REPO, path), "utf8");
const BASE = "http://192.168.0.80:8000/v1";
/** A profile id as the parser mints it. */
const pid = (id: number): ProfileId => id as ProfileId;

/** Pi's catalog entries under the primaries' provider: id -> contextWindow, parsed, never cast. */
function catalogWindows(): ReadonlyMap<string, number> {
	const root: unknown = JSON.parse(read("pi/models.json"));
	const providers = isRecord(root) ? root.providers : undefined;
	const provider = isRecord(providers) ? providers[PRIMARY_PROVIDER] : undefined;
	const models: unknown = isRecord(provider) ? provider.models : undefined;
	const entries = Array.isArray(models)
		? models.flatMap((model: unknown) =>
				isRecord(model) && typeof model.id === "string" && typeof model.contextWindow === "number"
					? [[model.id, model.contextWindow] as const]
					: [],
			)
		: [];
	return new Map(entries);
}

const SERVED: Readonly<Record<Primary, string>> = {
	glm: "glm-5.3-flash-hyperflare-tp2-v16",
	uncensored: "glm-5.3-flash-hyperflare-tp2-uncensored",
	warmind: "warmind-1017-native",
	deepseek: "deepseek-v4.1-flash-native",
	"glm-native": "glm-5.3-native",
	"uncensored-native": "glm-5.3-uncensored-native",
	"cyber-native": "glm-5.3-cyber-native",
};

const targetFor = (primary: Primary): ArtexTarget => {
	const window = catalogWindows().get(SERVED[primary]);
	if (window === undefined) throw new Error(`${SERVED[primary]} missing from pi/models.json`);
	return artexTarget(primary, { id: SERVED[primary], baseUrl: BASE, contextWindow: window });
};

describe("the engines, against their launchers", () => {
	it("puts each primary on the engine switch-primary.sh starts it with", () => {
		// start_primary's case arms name the launcher each primary runs through.
		const script = read("scripts/inference/switch-primary.sh");
		const body = /^start_primary\(\) \{\n([\s\S]*?)\n\}/m.exec(script)?.[1] ?? "";
		const launchers: Readonly<Record<string, Engine>> = {
			GLM_SWITCH: "hyperflare",
			DS41_RUN: "ds4-native",
			GLM_NATIVE_RUN: "glm53-native",
		};
		const fromScript = new Map<string, Engine>();
		for (const [, arm, launcher] of body.matchAll(/^\s+([a-z| -]+)\) .*"\$(\w+)"/gm)) {
			for (const primary of arm.split("|").map((word) => word.trim())) fromScript.set(primary, launchers[launcher]);
		}
		expect(Object.fromEntries(fromScript)).toEqual({ ...ENGINE_OF });
	});

	it("gives each engine the Lanes its launcher configures", () => {
		const ds41 = read("scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh");
		expect(Number(/^LANES="\$\{LANES:-(\d+)\}"$/m.exec(ds41)?.[1])).toBe(ENGINE_LANES["ds4-native"]);
		const hyperflare = read("scripts/inference/glm53/run-glm53-flash-hyperflare-tp2-v16.sh");
		expect(Number(/package: (\d+) slots/.exec(hyperflare)?.[1])).toBe(ENGINE_LANES.hyperflare);
		expect(read("scripts/inference/glm53/glm53-native/run-glm53-native.sh")).toContain("One request at a time");
		expect(ENGINE_LANES["glm53-native"]).toBe(1);
	});

	it("hands ARTEX every primary's context window inside the range ARTEX takes as given", () => {
		// ARTEX clamps context_window_k to [32, 1000]; a value outside would be silently changed.
		for (const primary of PRIMARIES) {
			const { contextWindowK: k } = targetFor(primary);
			expect(k).toBeGreaterThanOrEqual(32);
			expect(k).toBeLessThanOrEqual(1000);
			expect(k * 1000).toBeLessThanOrEqual(catalogWindows().get(SERVED[primary]) ?? 0);
		}
		expect(contextWindowK(202_752)).toBe(202);
		expect(contextWindowK(262_144)).toBe(262);
	});
});

describe("the agent shape an engine allows", () => {
	const LANES = Array.from({ length: 64 }, (_, i) => i + 1);
	const callers = ({ workers, tasks }: { workers: number; tasks: number }) => tasks * (1 + workers);

	it("stays within ARTEX's bounds for every Lane count", () => {
		for (const lanes of LANES) {
			const shape = agentShapeFor(lanes);
			expect(shape.workers).toBeGreaterThanOrEqual(1);
			expect(shape.workers).toBeLessThanOrEqual(MAX_WORKERS);
			expect(shape.tasks).toBeGreaterThanOrEqual(1);
		}
	});

	it("never has more callers than Lanes, except ARTEX's floor of one task and one worker", () => {
		for (const lanes of LANES) expect(callers(agentShapeFor(lanes))).toBeLessThanOrEqual(Math.max(lanes, 2));
	});

	it("is the widest that fits: one more task would not", () => {
		for (const lanes of LANES.filter((n) => n >= 2)) {
			const shape = agentShapeFor(lanes);
			expect(callers({ ...shape, tasks: shape.tasks + 1 })).toBeGreaterThan(lanes);
		}
	});

	it("never takes callers away as Lanes grow", () => {
		for (const lanes of LANES.slice(1)) expect(callers(agentShapeFor(lanes))).toBeGreaterThanOrEqual(callers(agentShapeFor(lanes - 1)));
	});

	it("is one worker on one task for GLM-5.3 full, and wider for the Flash engines", () => {
		expect(agentShapeFor(ENGINE_LANES["glm53-native"])).toEqual({ workers: 1, tasks: 1 });
		expect(agentShapeFor(ENGINE_LANES["ds4-native"])).toEqual({ workers: 3, tasks: 1 });
		expect(agentShapeFor(ENGINE_LANES.hyperflare)).toEqual({ workers: 3, tasks: 2 });
	});
});

describe("parsing ARTEX's replies", () => {
	it("reads profiles as ARTEX lists them: string ids, base_url omitted when empty", () => {
		const parsed = parseProfiles({
			profiles: [
				{ id: "3", name: "warmind-1017-native", format: "openai", base_url: BASE, model: "warmind-1017-native", context_window_k: 256, is_default: true, api_key_hint: "…6/M=" },
				{ id: 7, name: "cloud", format: "anthropic", model: "x", context_window_k: 0, is_default: false },
			],
		});
		expect(parsed).toEqual({
			ok: true,
			value: [
				{ id: pid(3), name: "warmind-1017-native", format: "openai", baseUrl: BASE, model: "warmind-1017-native", contextWindowK: 256, active: true },
				{ id: pid(7), name: "cloud", format: "anthropic", baseUrl: "", model: "x", contextWindowK: 0, active: false },
			],
		});
	});

	it("refuses replies that are not profiles", () => {
		const good = { id: "1", name: "a", format: "openai", model: "m", context_window_k: 1, is_default: false };
		for (const body of [
			undefined,
			{ profiles: "x" },
			{ profiles: [{ ...good, id: "0" }] },
			{ profiles: [{ ...good, id: "1e3" }] },
			{ profiles: [{ ...good, id: -2 }] },
			{ profiles: [{ ...good, model: 5 }] },
			{ profiles: [{ ...good, context_window_k: 1.5 }] },
			{ profiles: [{ ...good, is_default: "yes" }] },
		]) {
			expect(parseProfiles(body).ok).toBe(false);
		}
	});

	it("reads settings into one task-limit state", () => {
		expect(parseSettings({ workers: 3, task_concurrency_enabled: false, task_concurrency_limit: 5 })).toEqual({
			ok: true,
			value: { workers: 3, taskLimit: { kind: "unlimited" } },
		});
		expect(parseSettings({ workers: 1, task_concurrency_enabled: true, task_concurrency_limit: 1 })).toEqual({
			ok: true,
			value: { workers: 1, taskLimit: { kind: "limited", tasks: 1 } },
		});
		for (const body of [
			null,
			{ workers: 0, task_concurrency_enabled: true, task_concurrency_limit: 1 },
			{ workers: 1, task_concurrency_enabled: true, task_concurrency_limit: 0 },
			{ workers: 2 },
		]) {
			expect(parseSettings(body).ok).toBe(false);
		}
	});

	it("reads a saved profile's id", () => {
		expect(parseSavedId({ id: 4 })).toEqual({ ok: true, value: pid(4) });
		expect(parseSavedId({ id: "4" })).toEqual({ ok: true, value: pid(4) });
		expect(parseSavedId({}).ok).toBe(false);
	});

	it("round-trips a profile through the adapter's body, ARTEX's storage and the parser", () => {
		const fake = fakeArtex();
		const fields = profileFields(targetFor("uncensored-native"));
		fake.saveProfile(profileBody({ kind: "create", fields, apiKey: "k" }));
		const parsed = parseProfiles(fake.listProfiles());
		expect(parsed).toEqual({ ok: true, value: [{ id: pid(1), ...fields, active: false }] });
	});
});

describe("planning a sync", () => {
	const settings = { workers: 1, taskLimit: { kind: "limited", tasks: 1 } } as const;
	const target = () => targetFor("uncensored-native");
	const managed = (extra: Partial<ArtexProfile> = {}): ArtexProfile => ({
		id: pid(4),
		name: MANAGED_PROFILE,
		format: "openai",
		model: "glm-5.3-uncensored-native",
		baseUrl: BASE,
		contextWindowK: 202,
		active: true,
		...extra,
	});

	it("has nothing to do when ARTEX already matches", () => {
		const plan = planArtexSync(target(), { profiles: [managed()], settings });
		expect(plan).toEqual({ ok: true, value: { profile: { kind: "keep", id: pid(4), activate: false }, writeShape: false, drift: [] } });
	});

	it("names every difference", () => {
		const plan = planArtexSync(target(), {
			profiles: [managed({ model: "warmind-1017-native", contextWindowK: 256, active: false }), managed({ id: pid(3), name: "other" })],
			settings: { workers: 3, taskLimit: { kind: "unlimited" } },
		});
		expect(plan.ok && plan.value.drift).toEqual([
			`${MANAGED_PROFILE} model warmind-1017-native → glm-5.3-uncensored-native`,
			`${MANAGED_PROFILE} context 256K → 202K`,
			`activate ${MANAGED_PROFILE} (was other)`,
			"workers 3 → 1",
			"tasks at once unlimited → 1",
		]);
		expect(plan.ok && plan.value.profile).toEqual({ kind: "update", id: pid(4), activate: true });
	});

	it("refuses two profiles with the managed name", () => {
		const plan = planArtexSync(target(), { profiles: [managed(), managed({ id: pid(9) })], settings });
		expect(plan).toEqual({ ok: false, error: { kind: "ambiguous", count: 2 } });
	});
});

/** The starting points: the managed profile absent or off in each field, other profiles, every settings mix. */
function initialStates(): ReadonlyArray<Readonly<{ rows: readonly FakeRow[]; settings: FakeSettings }>> {
	const others: ReadonlyArray<readonly FakeRow[]> = [
		[],
		[desktopRow(1, "default", "glm-5.3-flash-hyperflare-tp2-uncensored"), desktopRow(3, "warmind-1017-native", "warmind-1017-native", { is_default: true })],
	];
	const managedRows: ReadonlyArray<FakeRow | undefined> = [
		undefined,
		desktopRow(4, MANAGED_PROFILE, "glm-5.3-native", { context_window_k: 64 }),
		desktopRow(4, MANAGED_PROFILE, "glm-5.3-uncensored-native", { context_window_k: 202, is_default: true }),
		desktopRow(4, MANAGED_PROFILE, "glm-5.3-uncensored-native", { context_window_k: 202, base_url: "" }),
		desktopRow(4, MANAGED_PROFILE, "warmind-1017-native", { format: "anthropic", is_default: true }),
	];
	const settings: readonly FakeSettings[] = [1, 3, 5].flatMap((workers) =>
		[true, false].flatMap((enabled) => [1, 2, 5].map((limit) => ({ workers, task_concurrency_enabled: enabled, task_concurrency_limit: limit }))),
	);
	// ARTEX activates in one transaction that clears every other is_default: at most one is active.
	const withManaged = (rows: readonly FakeRow[], row: FakeRow | undefined): readonly FakeRow[] =>
		row === undefined ? rows : [...rows.map((other) => (row.is_default ? { ...other, is_default: false } : other)), row];
	return others.flatMap((rows) => managedRows.flatMap((row) => settings.map((s) => ({ rows: withManaged(rows, row), settings: s }))));
}

describe("syncing ARTEX (model-based, over every starting point and primary)", () => {
	const starts = initialStates();

	it("ends on the target, touching nothing but the managed profile and the shape", async () => {
		for (const primary of PRIMARIES) {
			const target = targetFor(primary);
			for (const start of starts) {
				const fake = fakeArtex(start);
				const sync = await syncArtex(target, fakeArtexPort(fake), "apply");
				expect(sync.kind).toBe("synced");
				const mine = fake.rows().filter((row) => row.name === MANAGED_PROFILE);
				expect(mine).toHaveLength(1);
				expect(mine[0]).toMatchObject({ model: target.model, context_window_k: target.contextWindowK, base_url: BASE, format: "openai", is_default: true });
				expect(fake.rows().filter((row) => row.is_default)).toHaveLength(1);
				for (const before of start.rows.filter((row) => row.name !== MANAGED_PROFILE)) {
					expect(fake.rows().find((row) => row.id === before.id)).toEqual({ ...before, is_default: false });
				}
				expect(fake.settings()).toEqual({ workers: target.shape.workers, task_concurrency_enabled: true, task_concurrency_limit: target.shape.tasks });
			}
		}
	});

	it("is idempotent: a second sync changes nothing and writes nothing", async () => {
		for (const primary of PRIMARIES) {
			for (const start of starts) {
				const fake = fakeArtex(start);
				await syncArtex(targetFor(primary), fakeArtexPort(fake), "apply");
				const writes = fake.writes.length;
				const again = await syncArtex(targetFor(primary), fakeArtexPort(fake), "apply");
				expect(again).toMatchObject({ kind: "synced", changes: [] });
				expect(fake.writes.length).toBe(writes);
			}
		}
	});

	it("checks without writing, and predicts exactly what an apply changes", async () => {
		for (const start of starts) {
			const fake = fakeArtex(start);
			const checked = await syncArtex(targetFor("glm-native"), fakeArtexPort(fake), "check");
			expect(fake.writes).toEqual([]);
			const applied = await syncArtex(targetFor("glm-native"), fakeArtexPort(fake), "apply");
			expect(checked.kind === "checked" && applied.kind === "synced" && checked.drift).toEqual(applied.kind === "synced" ? applied.changes : []);
		}
	});

	it("keeps the stored key on update and gives a created profile the provider's", async () => {
		const updated = fakeArtex({ rows: [desktopRow(4, MANAGED_PROFILE, "glm-5.3-native", { api_key: "kept-key" })] });
		await syncArtex(targetFor("deepseek"), fakeArtexPort(updated), "apply");
		expect(updated.rows()[0]?.api_key).toBe("kept-key");
		const created = fakeArtex();
		await syncArtex(targetFor("deepseek"), fakeArtexPort(created, { key: async () => "provider-key" }), "apply");
		expect(created.rows()[0]?.api_key).toBe("provider-key");
	});
});

describe("syncing ARTEX when calls misbehave", () => {
	const writeCalls: readonly ArtexCall[] = ["save profile", "activate profile", "write settings"];
	const fresh = () => fakeArtex({ rows: [desktopRow(3, "warmind-1017-native", "warmind-1017-native", { is_default: true })] });

	it("converges after a lost reply, without a second managed profile", async () => {
		for (const call of writeCalls) {
			const fake = fresh();
			const port = fakeArtexPort(fake, { faults: [{ call, how: "lose-reply" }] });
			const first = await syncArtex(targetFor("cyber-native"), port, "apply");
			expect(first).toEqual({ kind: "failed", error: { kind: "request", call, detail: `${call}: connection reset` } });
			const second = await syncArtex(targetFor("cyber-native"), port, "apply");
			expect(second.kind).toBe("synced");
			expect(fake.rows().filter((row) => row.name === MANAGED_PROFILE)).toHaveLength(1);
		}
	});

	it("stops at a refused write and attempts nothing after it", async () => {
		const fake = fresh();
		const sync = await syncArtex(targetFor("cyber-native"), fakeArtexPort(fake, { faults: [{ call: "save profile", how: "refuse" }] }), "apply");
		expect(sync).toEqual({ kind: "failed", error: { kind: "request", call: "save profile", detail: "save profile refused" } });
		expect(fake.writes).toEqual([]);
	});

	it("fails as unsettled when ARTEX accepts a write it does not apply", async () => {
		const fake = fresh();
		const sync = await syncArtex(targetFor("cyber-native"), fakeArtexPort(fake, { faults: [{ call: "write settings", how: "ignore" }] }), "apply");
		expect(sync).toEqual({ kind: "failed", error: { kind: "unsettled", drift: ["workers 3 → 1", "tasks at once unlimited → 1"] } });
	});

	it("fails on an unreadable ARTEX before writing anything", async () => {
		const fake = fresh();
		const sync = await syncArtex(targetFor("glm"), fakeArtexPort(fake, { faults: [{ call: "read settings", how: "refuse" }] }), "apply");
		expect(sync).toEqual({ kind: "failed", error: { kind: "request", call: "read settings", detail: "read settings refused" } });
		expect(fake.writes).toEqual([]);
	});

	it("fails without writing when a new profile has no key to carry", async () => {
		const fake = fresh();
		const port = fakeArtexPort(fake, { key: async () => { throw new Error("no API key for desktop-vllm"); } });
		const sync = await syncArtex(targetFor("glm"), port, "apply");
		expect(sync).toEqual({ kind: "failed", error: { kind: "request", call: "save profile", detail: "no API key for desktop-vllm" } });
		expect(fake.writes).toEqual([]);
	});

	it("maps a reply that does not parse to a reply error, writing nothing", async () => {
		const profiles = fresh();
		const badProfiles: ArtexPort = { ...fakeArtexPort(profiles), readProfiles: async () => ({ profiles: "x" }) };
		expect(await syncArtex(targetFor("glm"), badProfiles, "apply")).toEqual({
			kind: "failed",
			error: { kind: "reply", call: "read profiles", detail: "no profiles list" },
		});
		expect(profiles.writes).toEqual([]);

		const settings = fresh();
		const badSettings: ArtexPort = { ...fakeArtexPort(settings), readSettings: async () => ({ workers: 0 }) };
		expect(await syncArtex(targetFor("glm"), badSettings, "apply")).toEqual({
			kind: "failed",
			error: { kind: "reply", call: "read settings", detail: "no positive workers count" },
		});
		expect(settings.writes).toEqual([]);
	});

	it("refuses an ambiguous managed profile, writing nothing", async () => {
		const fake = fakeArtex({
			rows: [desktopRow(4, MANAGED_PROFILE, "glm-5.3-native"), desktopRow(5, MANAGED_PROFILE, "glm-5.3-uncensored-native")],
		});
		expect(await syncArtex(targetFor("glm"), fakeArtexPort(fake), "apply")).toEqual({
			kind: "failed",
			error: { kind: "ambiguous", count: 2 },
		});
		expect(fake.writes).toEqual([]);
	});
});

describe("describing a sync", () => {
	const target = (): ArtexTarget => targetFor("uncensored-native");

	it("says what changed, and that running tasks keep their workers", () => {
		const sync: ArtexSync = { kind: "synced", target: target(), changes: ["workers 3 → 1", "tasks at once unlimited → 1"] };
		expect(describeArtexSync(sync)).toBe(
			"ARTEX now on glm-5.3-uncensored-native (202K), 1 worker a task, 1 task at once (workers 3 → 1; tasks at once unlimited → 1). Running tasks keep their workers.",
		);
	});

	it("says when nothing changed, and plural shapes read right", () => {
		expect(describeArtexSync({ kind: "synced", target: targetFor("glm"), changes: [] })).toBe(
			"ARTEX already on glm-5.3-flash-hyperflare-tp2-v16 (400K), 3 workers a task, 2 tasks at once.",
		);
	});

	it("reports status drift, skips and failures", () => {
		expect(describeArtexSync({ kind: "checked", target: target(), drift: [] })).toStartWith("artex:      in sync:");
		expect(describeArtexSync({ kind: "checked", target: target(), drift: ["workers 3 → 1"] })).toBe(
			"artex:      out of sync; /switch to this primary would: workers 3 → 1",
		);
		expect(describeArtexSync({ kind: "skipped", reason: "no primary serves" })).toBe("ARTEX not synced: no primary serves.");
		expect(describeArtexSync({ kind: "failed", error: { kind: "ambiguous", count: 2 } })).toContain("2 profiles are named desktop-primary");
		expect(describeArtexSync({ kind: "failed", error: { kind: "setup", detail: "x is readable by others" } })).toBe(
			"ARTEX sync failed: x is readable by others",
		);
	});
});
