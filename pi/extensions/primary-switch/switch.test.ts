import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Result } from "../model-routing/policy";
import {
	failureTail,
	observe,
	parseSwitchReport,
	parseSwitchRequest,
	runPrimarySwitch,
	SWITCH_REQUESTS,
	switchCompletions,
	type ScriptRun,
	type SwitchPorts,
	type SwitchRequest,
} from "./switch";

const GLM = "glm-5.3-flash-hyperflare-tp2-v16";
const WARMIND = "warmind-1017-native";
const SCRIPT = join(import.meta.dir, "../../../scripts/inference/switch-primary.sh");

const reportOf = (primary: string, served: string, extra = ""): string =>
	`switching: warmind -> ${primary}\nPRIMARY: ${primary} (${served} on :8000)\npi:      pi --model desktop-vllm/${served}\n${extra}`;

/** Plain fakes: a scripted run, a queue of probe answers, a fake clock that sleep advances. */
function fakePorts(options: Readonly<{
	run?: ScriptRun;
	probes?: ReadonlyArray<Result<string, string>>;
	select?: Result<string, string>;
}> = {}) {
	let clock = 0;
	const calls = { scripts: [] as SwitchRequest[], probes: 0, selected: [] as string[], progress: [] as Array<string | undefined> };
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
			return options.select ?? { ok: true, value: `desktop-vllm/${servedId}` };
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
		expect(switchCompletions("g").map((item) => item.value)).toEqual(["glm"]);
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

	it("matches the exact line the script prints, and the script's request words", () => {
		const source = readFileSync(SCRIPT, "utf8");
		expect(source).toContain('echo "PRIMARY: $primary ($served on :8000)"');
		expect(source).toContain('echo "(already the primary; nothing to do)"');
		expect(source).toContain("Usage: switch-primary.sh [toggle|glm|warmind|deepseek|status]");
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
		expect(outcome).toEqual({ kind: "switched", primary: "glm", model: `desktop-vllm/${GLM}`, unchanged: false, waitedMs: 6_000 });
		expect(calls.scripts).toEqual(["glm"]);
		expect(calls.probes).toBe(3);
		expect(calls.selected).toEqual([GLM]);
		expect(calls.progress.at(-1)).toBeUndefined();
		expect(calls.progress).toContain(`waiting for ${GLM}: still serving ${WARMIND}`);
	});

	it("still moves the session onto the primary when it already serves", async () => {
		const { ports, calls } = fakePorts({
			run: { code: 0, stdout: reportOf("warmind", WARMIND, "(already the primary; nothing to do)\n"), stderr: "", killed: false },
			probes: [{ ok: true, value: WARMIND }],
		});
		const outcome = await runPrimarySwitch("warmind", ports, timing);
		expect(outcome).toEqual({ kind: "switched", primary: "warmind", model: `desktop-vllm/${WARMIND}`, unchanged: true, waitedMs: 0 });
		expect(calls.selected).toEqual([WARMIND]);
	});

	it("reports status without probing or touching the session model", async () => {
		const { ports, calls } = fakePorts({
			run: { code: 0, stdout: "active:     glm (glm-5.3)\nlast:       warmind\ntoggle ->   start:warmind\n", stderr: "", killed: false },
		});
		const outcome = await runPrimarySwitch("status", ports, timing);
		expect(outcome).toEqual({ kind: "status", text: "active:     glm (glm-5.3)\nlast:       warmind\ntoggle ->   start:warmind" });
		expect(calls.probes).toBe(0);
		expect(calls.selected).toEqual([]);
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

	it("clears progress even when a port throws", async () => {
		const { ports, calls } = fakePorts();
		const throwing: SwitchPorts = { ...ports, runScript: async () => { throw new Error("boom"); } };
		await expect(runPrimarySwitch("glm", throwing, timing)).rejects.toThrow("boom");
		expect(calls.progress.at(-1)).toBeUndefined();
	});
});
