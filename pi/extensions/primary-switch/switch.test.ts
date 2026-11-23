import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Result } from "../model-routing/policy";
import type { ArtexMode, ArtexSync } from "./artex";
import {
	failureTail,
	observe,
	PRIMARIES,
	PRIMARY_PROVIDER,
	parseStatusActive,
	parseSwitchReport,
	parseSwitchRequest,
	runPrimarySwitch,
	SWITCH_REQUESTS,
	switchCompletions,
	type Primary,
	type ScriptRun,
	type SwitchPorts,
	type SwitchRequest,
} from "./switch";

const GLM = "glm-5.3-flash-hyperflare-tp2-v16";
const UNCENSORED = "glm-5.3-flash-hyperflare-tp2-uncensored";
const WARMIND = "warmind-1017-native";
/** Every primary's served id; the Record type makes a new primary a compile error until it is listed. */
const SERVED: Readonly<Record<Primary, string>> = {
	glm: GLM,
	uncensored: UNCENSORED,
	warmind: WARMIND,
	deepseek: "deepseek-v4.1-flash-native",
	"glm-native": "glm-5.3-native",
	"uncensored-native": "glm-5.3-uncensored-native",
	"cyber-native": "glm-5.3-cyber-native",
};
const SCRIPT = join(import.meta.dir, "../../../scripts/inference/switch-primary.sh");
const CATALOG = join(import.meta.dir, "../../models.json");

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

/** The model ids Pi's catalog offers under the primaries' provider, parsed from the file, never cast. */
function catalogModelIds(): readonly string[] {
	const root: unknown = JSON.parse(readFileSync(CATALOG, "utf8"));
	const providers = isRecord(root) ? root.providers : undefined;
	const provider = isRecord(providers) ? providers[PRIMARY_PROVIDER] : undefined;
	const models: unknown = isRecord(provider) ? provider.models : undefined;
	return Array.isArray(models)
		? models.flatMap((model: unknown) => (isRecord(model) && typeof model.id === "string" ? [model.id] : []))
		: [];
}

const reportOf = (primary: string, served: string, extra = ""): string =>
	`switching: warmind -> ${primary}\nPRIMARY: ${primary} (${served} on :8000)\npi:      pi --model desktop-vllm/${served}\n${extra}`;

/** What the fake ARTEX port answers unless a test says otherwise. */
const ARTEX_SYNCED: ArtexSync = { kind: "skipped", reason: "fake ARTEX" };

/** Plain fakes: a scripted run, a queue of probe answers, a fake clock that sleep advances. */
function fakePorts(options: Readonly<{
	run?: ScriptRun;
	probes?: ReadonlyArray<Result<string, string>>;
	select?: Result<string, string>;
	artex?: ArtexSync;
}> = {}) {
	let clock = 0;
	const calls = {
		scripts: [] as SwitchRequest[],
		probes: 0,
		selected: [] as string[],
		artex: [] as Array<readonly [Primary, string, ArtexMode]>,
		/** Every port call in order, to check what happens before what. */
		order: [] as string[],
		progress: [] as Array<string | undefined>,
	};
	const probes = [...(options.probes ?? [{ ok: true, value: GLM }])];
	const ports: SwitchPorts = {
		runScript: async (request) => {
			calls.scripts.push(request);
			return options.run ?? { code: 0, stdout: reportOf("glm", GLM), stderr: "", killed: false };
		},
		probeServed: async () => {
			calls.probes++;
			return probes.length > 1 ? probes.shift()! : probes[0];
		},
		selectModel: async (servedId) => {
			calls.selected.push(servedId);
			calls.order.push("select");
			return options.select ?? { ok: true, value: `desktop-vllm/${servedId}` };
		},
		artex: async (primary, servedId, mode) => {
			calls.artex.push([primary, servedId, mode]);
			calls.order.push(`artex:${mode}`);
			return options.artex ?? ARTEX_SYNCED;
		},
		sleep: async (ms) => {
			clock += ms;
		},
		now: () => clock,
		progress: (text) => calls.progress.push(text),
	};
	return { ports, calls };
}

const timing = { pollIntervalMs: 3_000, serveTimeoutMs: 30_000 };

describe("parsing the /switch request", () => {
	it("defaults to toggle and accepts exactly one known word, in any case", () => {
		expect(parseSwitchRequest("")).toEqual({ ok: true, value: "toggle" });
		expect(parseSwitchRequest("   ")).toEqual({ ok: true, value: "toggle" });
		for (const word of SWITCH_REQUESTS) {
			expect(parseSwitchRequest(word)).toEqual({ ok: true, value: word });
			expect(parseSwitchRequest(`  ${word.toUpperCase()} `)).toEqual({ ok: true, value: word });
		}
	});

	it("refuses unknown words and extra arguments with the usage", () => {
		for (const args of ["qwen", "glm warmind", "--force", "stop"]) {
			const parsed = parseSwitchRequest(args);
			expect(parsed.ok).toBe(false);
			if (!parsed.ok) expect(parsed.error).toContain("usage: /switch");
		}
	});

	it("completes request words by prefix, each with a description", () => {
		expect(switchCompletions("").map((item) => item.value)).toEqual([...SWITCH_REQUESTS]);
		expect(switchCompletions("g").map((item) => item.value)).toEqual(["glm", "glm-native"]);
		expect(switchCompletions("glm-").map((item) => item.value)).toEqual(["glm-native"]);
		expect(switchCompletions("u").map((item) => item.value)).toEqual(["uncensored", "uncensored-native"]);
		expect(switchCompletions("c").map((item) => item.value)).toEqual(["cyber-native"]);
		expect(switchCompletions("x")).toEqual([]);
		expect(switchCompletions("").every((item) => item.description.length > 0)).toBe(true);
	});
});

describe("parsing the switch-primary.sh report", () => {
	it("reads the primary and its served id, and whether it was a no-op", () => {
		expect(parseSwitchReport(reportOf("glm", GLM))).toEqual({
			ok: true,
			value: { primary: "glm", servedId: GLM, unchanged: false },
		});
		expect(parseSwitchReport(reportOf("warmind", WARMIND, "(already the primary; nothing to do)\n"))).toEqual({
			ok: true,
			value: { primary: "warmind", servedId: WARMIND, unchanged: true },
		});
	});

	it("refuses output without the report line", () => {
		expect(parseSwitchReport("switching: glm -> warmind\n").ok).toBe(false);
		expect(parseSwitchReport("PRIMARY: glm\n").ok).toBe(false);
	});

	it("parses what the script's own report function prints, for every primary", () => {
		// Golden test across the seam: run switch-primary.sh's real `report` (sourcing
		// the script defines functions only) and parse its output.
		const report = (...args: string[]): string => {
			const run = Bun.spawnSync(["bash", "-c", 'source "$1"; shift; report "$@"', "bash", SCRIPT, ...args]);
			if (run.exitCode !== 0) throw new Error(run.stderr.toString());
			return run.stdout.toString();
		};
		for (const primary of PRIMARIES) {
			expect(parseSwitchReport(report(primary))).toEqual({
				ok: true,
				value: { primary, servedId: SERVED[primary], unchanged: false },
			});
			expect(parseSwitchReport(report(primary, "noop"))).toEqual({
				ok: true,
				value: { primary, servedId: SERVED[primary], unchanged: true },
			});
		}
		expect(readFileSync(SCRIPT, "utf8")).toContain("Usage: switch-primary.sh [toggle|PRIMARY|status]");
		// The script's primary list is exactly Pi's: is_primary accepts each, and its message names them all.
		const script = readFileSync(SCRIPT, "utf8");
		const names = /^PRIMARY_NAMES="([^"]+)"$/m.exec(script)?.[1] ?? "";
		expect(names.split(/, | or /)).toEqual([...PRIMARIES]);
	});

	it("has a catalog model for every primary's served id", () => {
		// A primary without a catalog entry would finish its cutover and then fail at the
		// `model` stage ("is served but missing from pi/models.json"); catch that here.
		const offered = catalogModelIds();
		for (const primary of PRIMARIES) expect(offered).toContain(SERVED[primary]);
	});

	it("reads the active primary from what the script's own status prints", () => {
		// Golden across the seam: run_request status with the container reads stubbed.
		const status = (active: string): string => {
			const run = Bun.spawnSync([
				"bash",
				"-c",
				'ACTIVE="$2"; source "$1"; read_active() { echo "$ACTIVE"; }; read_last() { echo glm; }; run_request status',
				"bash",
				SCRIPT,
				active,
			]);
			if (run.exitCode !== 0) throw new Error(run.stderr.toString());
			return run.stdout.toString();
		};
		for (const primary of PRIMARIES) expect(parseStatusActive(status(primary))).toEqual({ primary, servedId: SERVED[primary] });
		expect(parseStatusActive(status("none"))).toBeUndefined();
		expect(parseStatusActive(status("multiple"))).toBeUndefined();
	});

	it("refuses a report naming a primary the script does not have", () => {
		expect(parseSwitchReport("PRIMARY: x (y on :8000)\n")).toEqual({
			ok: false,
			error: 'switch-primary.sh reported an unknown primary "x"',
		});
	});

	it("keeps the meaningful tail of a failure and drops ssh banners", () => {
		const stderr = "** WARNING: connection is not using a post-quantum key exchange algorithm.\nerror: :8000 is busy (2 in flight)\n";
		expect(failureTail("switching: glm -> warmind\n", stderr)).toBe("error: :8000 is busy (2 in flight)");
		expect(failureTail("only stdout\n", "")).toBe("only stdout");
		expect(failureTail("", "")).toBe("no output");
		expect(failureTail("", Array.from({ length: 10 }, (_, i) => `line ${i}`).join("\n"), 3)).toBe("line 7\nline 8\nline 9");
	});
});

describe("judging one probe", () => {
	it("is served only when the provider serves exactly the reported id", () => {
		expect(observe(GLM, { ok: true, value: GLM })).toEqual({ kind: "served" });
		expect(observe(GLM, { ok: true, value: WARMIND })).toEqual({ kind: "pending", detail: `still serving ${WARMIND}` });
		expect(observe(GLM, { ok: false, error: "cannot reach desktop-vllm: ECONNREFUSED" })).toEqual({
			kind: "pending",
			detail: "cannot reach desktop-vllm: ECONNREFUSED",
		});
	});
});

describe("running a switch", () => {
	it("switches, polls through the cutover, then selects the served model", async () => {
		const { ports, calls } = fakePorts({
			probes: [
				{ ok: false, error: "cannot reach desktop-vllm: ECONNREFUSED" },
				{ ok: true, value: WARMIND },
				{ ok: true, value: GLM },
			],
		});
		const outcome = await runPrimarySwitch("glm", ports, timing);
		expect(outcome).toEqual({ kind: "switched", primary: "glm", model: `desktop-vllm/${GLM}`, unchanged: false, waitedMs: 6_000, artex: ARTEX_SYNCED });
		expect(calls.scripts).toEqual(["glm"]);
		expect(calls.probes).toBe(3);
		expect(calls.selected).toEqual([GLM]);
		// ARTEX moves only once the model serves and this session is on it.
		expect(calls.order).toEqual(["select", "artex:apply"]);
		expect(calls.artex).toEqual([["glm", GLM, "apply"]]);
		expect(calls.progress.at(-1)).toBeUndefined();
		expect(calls.progress).toContain(`waiting for ${GLM}: still serving ${WARMIND}`);
	});

	it("waits for uncensored's own id while the other Hyperflare primary still serves", async () => {
		// GLM and uncensored share an engine and a port; only the served id tells them apart.
		const { ports, calls } = fakePorts({
			run: { code: 0, stdout: reportOf("uncensored", UNCENSORED), stderr: "", killed: false },
			probes: [
				{ ok: true, value: GLM },
				{ ok: true, value: UNCENSORED },
			],
		});
		const outcome = await runPrimarySwitch("uncensored", ports, timing);
		expect(outcome).toEqual({ kind: "switched", primary: "uncensored", model: `desktop-vllm/${UNCENSORED}`, unchanged: false, waitedMs: 3_000, artex: ARTEX_SYNCED });
		expect(calls.scripts).toEqual(["uncensored"]);
		expect(calls.progress).toContain(`waiting for ${UNCENSORED}: still serving ${GLM}`);
		expect(calls.selected).toEqual([UNCENSORED]);
	});

	it("still moves the session onto the primary when it already serves", async () => {
		const { ports, calls } = fakePorts({
			run: { code: 0, stdout: reportOf("warmind", WARMIND, "(already the primary; nothing to do)\n"), stderr: "", killed: false },
			probes: [{ ok: true, value: WARMIND }],
		});
		const outcome = await runPrimarySwitch("warmind", ports, timing);
		expect(outcome).toEqual({ kind: "switched", primary: "warmind", model: `desktop-vllm/${WARMIND}`, unchanged: true, waitedMs: 0, artex: ARTEX_SYNCED });
		expect(calls.selected).toEqual([WARMIND]);
		// A no-op switch still re-syncs ARTEX: `/switch <current>` is how to repair it.
		expect(calls.artex).toEqual([["warmind", WARMIND, "apply"]]);
	});

	it("succeeds when ARTEX fails, and carries ARTEX's failure beside it", async () => {
		const failed: ArtexSync = { kind: "failed", error: { kind: "request", call: "read profiles", detail: "ECONNREFUSED" } };
		const { ports } = fakePorts({ artex: failed });
		const outcome = await runPrimarySwitch("glm", ports, timing);
		expect(outcome).toEqual({ kind: "switched", primary: "glm", model: `desktop-vllm/${GLM}`, unchanged: false, waitedMs: 0, artex: failed });
	});

	it("reports status, checking ARTEX against the active primary without touching the session model", async () => {
		const { ports, calls } = fakePorts({
			run: { code: 0, stdout: "active:     glm (glm-5.3)\nlast:       warmind\ntoggle ->   start:uncensored\n", stderr: "", killed: false },
		});
		const outcome = await runPrimarySwitch("status", ports, timing);
		expect(outcome).toEqual({
			kind: "status",
			text: "active:     glm (glm-5.3)\nlast:       warmind\ntoggle ->   start:uncensored",
			artex: ARTEX_SYNCED,
		});
		expect(calls.probes).toBe(0);
		expect(calls.selected).toEqual([]);
		expect(calls.artex).toEqual([["glm", "glm-5.3", "check"]]);
	});

	it("reports status with nothing serving without asking ARTEX", async () => {
		const { ports, calls } = fakePorts({ run: { code: 0, stdout: "active:     none\nlast:       glm\n", stderr: "", killed: false } });
		const outcome = await runPrimarySwitch("status", ports, timing);
		expect(outcome).toEqual({ kind: "status", text: "active:     none\nlast:       glm", artex: { kind: "skipped", reason: "no primary serves" } });
		expect(calls.artex).toEqual([]);
	});

	it("surfaces an active line it cannot parse instead of reading it as nothing serving", async () => {
		// `none` means nothing serves; any other unparseable active line is a drift to show, not hide.
		const { ports, calls } = fakePorts({ run: { code: 0, stdout: "active:     multiple\nlast:       glm\n", stderr: "", killed: false } });
		const outcome = await runPrimarySwitch("status", ports, timing);
		expect(outcome).toEqual({
			kind: "status",
			text: "active:     multiple\nlast:       glm",
			artex: { kind: "skipped", reason: "status had no parseable active: line" },
		});
		expect(calls.artex).toEqual([]);
	});

	it("stops at a failed script with its reason, leaving the session model alone", async () => {
		const { ports, calls } = fakePorts({
			run: { code: 1, stdout: "switching: glm -> warmind\n", stderr: "error: warmind failed to start; restoring glm\n", killed: false },
		});
		const outcome = await runPrimarySwitch("warmind", ports, timing);
		expect(outcome).toEqual({
			kind: "failed",
			stage: "script",
			message: "switch-primary.sh exited 1:\nerror: warmind failed to start; restoring glm",
		});
		expect(calls.probes).toBe(0);
		expect(calls.selected).toEqual([]);
		expect(calls.progress.at(-1)).toBeUndefined();
	});

	it("names a killed script as a timeout", async () => {
		const { ports } = fakePorts({ run: { code: 143, stdout: "", stderr: "", killed: true } });
		const outcome = await runPrimarySwitch("toggle", ports, timing);
		expect(outcome.kind === "failed" && outcome.stage === "script" && outcome.message.includes("timeout")).toBe(true);
	});

	it("refuses a successful run without its report line", async () => {
		const { ports, calls } = fakePorts({ run: { code: 0, stdout: "something else\n", stderr: "", killed: false } });
		const outcome = await runPrimarySwitch("glm", ports, timing);
		expect(outcome.kind === "failed" && outcome.stage).toBe("report");
		expect(calls.selected).toEqual([]);
	});

	it("gives up when the reported model is never served, and does not select it", async () => {
		const { ports, calls } = fakePorts({ probes: [{ ok: true, value: WARMIND }] });
		const outcome = await runPrimarySwitch("glm", ports, timing);
		expect(outcome).toEqual({
			kind: "failed",
			stage: "serve",
			message: `${GLM} was not served within 30 s (still serving ${WARMIND})`,
		});
		expect(calls.probes).toBe(11);
		expect(calls.selected).toEqual([]);
	});

	it("reports a model the session cannot select", async () => {
		const { ports } = fakePorts({ select: { ok: false, error: `desktop-vllm/${GLM} is served but missing from pi/models.json` } });
		const outcome = await runPrimarySwitch("glm", ports, timing);
		expect(outcome).toEqual({ kind: "failed", stage: "model", message: `desktop-vllm/${GLM} is served but missing from pi/models.json` });
	});

	it("leaves ARTEX alone whenever the switch itself fails", async () => {
		const failing = [
			fakePorts({ run: { code: 1, stdout: "", stderr: "error: busy\n", killed: false } }),
			fakePorts({ run: { code: 0, stdout: "something else\n", stderr: "", killed: false } }),
			fakePorts({ probes: [{ ok: true, value: WARMIND }] }),
			fakePorts({ select: { ok: false, error: "no credentials for desktop-vllm" } }),
		];
		for (const { ports, calls } of failing) {
			expect((await runPrimarySwitch("glm", ports, timing)).kind).toBe("failed");
			expect(calls.artex).toEqual([]);
		}
	});

	it("clears progress even when a port throws", async () => {
		const { ports, calls } = fakePorts();
		const throwing: SwitchPorts = { ...ports, runScript: async () => { throw new Error("boom"); } };
		await expect(runPrimarySwitch("glm", throwing, timing)).rejects.toThrow("boom");
		expect(calls.progress.at(-1)).toBeUndefined();
	});
});
