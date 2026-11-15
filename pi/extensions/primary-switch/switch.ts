/**
 * `/switch`: change desktop's primary model and move this Pi session onto it.
 *
 * scripts/inference/switch-primary.sh owns the decision, the idle gate, the
 * cutover and the rollback; it also owns which served id each primary has and
 * reports it. This module only parses the request and that report, then polls
 * the provider until it serves the reported id, and selects that model. Every
 * effect goes through SwitchPorts, so the whole flow runs against plain fakes.
 */
import type { Result } from "../model-routing/policy.js";

/** The provider pi/models.json serves the primaries under; the verifier checks routing agrees. */
export const PRIMARY_PROVIDER = "desktop-vllm";

/** The primaries switch-primary.sh can report (it owns which served id each has). */
export const PRIMARIES = ["glm", "uncensored", "warmind", "deepseek"] as const;
export type Primary = (typeof PRIMARIES)[number];

/** The script's vocabulary (`switch-primary.sh [toggle|glm|uncensored|warmind|deepseek|status]`). */
export const SWITCH_REQUESTS = ["toggle", ...PRIMARIES, "status"] as const;
export type SwitchRequest = (typeof SWITCH_REQUESTS)[number];

const isPrimary = (word: string): word is Primary => (PRIMARIES as readonly string[]).includes(word);

const REQUEST_HELP: Readonly<Record<SwitchRequest, string>> = {
	toggle: "GLM or uncensored -> WARMIND; WARMIND or DeepSeek -> GLM",
	glm: "GLM-5.3 v16 on Hyperflare",
	uncensored: "GLM-5.3 uncensored on Hyperflare (dealignai's UNCENSORED build in v16's storage)",
	warmind: "WARMIND on ds4-native",
	deepseek: "stock DeepSeek-V4.1-Flash on ds4-native",
	status: "what serves now, and what toggle would do",
};

export const SWITCH_USAGE = `usage: /switch [${SWITCH_REQUESTS.join("|")}]  (default: toggle)`;

const isSwitchRequest = (word: string): word is SwitchRequest =>
	(SWITCH_REQUESTS as readonly string[]).includes(word);

/** Empty arguments mean toggle; anything else must be exactly one known word. */
export function parseSwitchRequest(args: string): Result<SwitchRequest, string> {
	const words = args.trim().toLowerCase().split(/\s+/).filter((word) => word !== "");
	if (words.length === 0) return { ok: true, value: "toggle" };
	if (words.length === 1 && isSwitchRequest(words[0])) return { ok: true, value: words[0] };
	return { ok: false, error: `unknown /switch argument "${args.trim()}"; ${SWITCH_USAGE}` };
}

export function switchCompletions(prefix: string): ReadonlyArray<Readonly<{ value: string; label: string; description: string }>> {
	const wanted = prefix.trim().toLowerCase();
	return SWITCH_REQUESTS.filter((request) => request.startsWith(wanted)).map((request) => ({
		value: request,
		label: request,
		description: REQUEST_HELP[request],
	}));
}

/** What the script reports after a switch or a no-op: `PRIMARY: <name> (<served-id> on :8000)`. */
export type SwitchReport = Readonly<{ primary: Primary; servedId: string; unchanged: boolean }>;

const REPORT_LINE = /^PRIMARY: (\S+) \((\S+) on :8000\)$/m;
const NOOP_LINE = "(already the primary; nothing to do)";

export function parseSwitchReport(stdout: string): Result<SwitchReport, string> {
	const match = REPORT_LINE.exec(stdout);
	if (!match) return { ok: false, error: "switch-primary.sh finished without its PRIMARY report line" };
	const primary = match[1];
	if (!isPrimary(primary)) return { ok: false, error: `switch-primary.sh reported an unknown primary "${primary}"` };
	return { ok: true, value: Object.freeze({ primary, servedId: match[2], unchanged: stdout.includes(NOOP_LINE) }) };
}

/** The last meaningful lines of a failed run, without ssh's own banner warnings. */
export function failureTail(stdout: string, stderr: string, lines: number = 6): string {
	const pick = (text: string) =>
		text.split("\n").map((line) => line.trimEnd()).filter((line) => line !== "" && !line.startsWith("** "));
	const fromStderr = pick(stderr);
	const chosen = fromStderr.length > 0 ? fromStderr : pick(stdout);
	return chosen.slice(-lines).join("\n") || "no output";
}

/** One probe of the provider, judged against the id the script reported. */
export type Observation =
	| Readonly<{ kind: "served" }>
	| Readonly<{ kind: "pending"; detail: string }>;

export function observe(targetId: string, probed: Result<string, string>): Observation {
	if (!probed.ok) return { kind: "pending", detail: probed.error };
	return probed.value === targetId
		? { kind: "served" }
		: { kind: "pending", detail: `still serving ${probed.value}` };
}

export type ScriptRun = Readonly<{ code: number; stdout: string; stderr: string; killed: boolean }>;

export type SwitchPorts = Readonly<{
	/** Run switch-primary.sh with one request word. */
	runScript: (request: SwitchRequest) => Promise<ScriptRun>;
	/** The id the local provider serves now, or why that is unknown. Never throws. */
	probeServed: () => Promise<Result<string, string>>;
	/** Make the session use the catalog model with this served id; returns its `provider/id`. */
	selectModel: (servedId: string) => Promise<Result<string, string>>;
	sleep: (ms: number) => Promise<void>;
	now: () => number;
	/** Footer progress; undefined clears it. */
	progress: (text: string | undefined) => void;
}>;

export type SwitchTiming = Readonly<{ pollIntervalMs: number; serveTimeoutMs: number }>;

export const DEFAULT_TIMING: SwitchTiming = Object.freeze({ pollIntervalMs: 3_000, serveTimeoutMs: 300_000 });

export type SwitchFailureStage = "script" | "report" | "serve" | "model";

export type SwitchOutcome =
	| Readonly<{ kind: "status"; text: string }>
	| Readonly<{ kind: "switched"; primary: Primary; model: string; unchanged: boolean; waitedMs: number }>
	| Readonly<{ kind: "failed"; stage: SwitchFailureStage; message: string }>;

/** Poll until the provider serves `targetId` or the deadline passes. */
export async function waitUntilServed(
	targetId: string,
	ports: Pick<SwitchPorts, "probeServed" | "sleep" | "now" | "progress">,
	timing: SwitchTiming,
): Promise<Result<number, string>> {
	const started = ports.now();
	for (;;) {
		const seen = observe(targetId, await ports.probeServed());
		const waited = ports.now() - started;
		if (seen.kind === "served") return { ok: true, value: waited };
		if (waited >= timing.serveTimeoutMs) {
			return { ok: false, error: `${targetId} was not served within ${Math.round(timing.serveTimeoutMs / 1000)} s (${seen.detail})` };
		}
		ports.progress(`waiting for ${targetId}: ${seen.detail}`);
		await ports.sleep(timing.pollIntervalMs);
	}
}

export async function runPrimarySwitch(
	request: SwitchRequest,
	ports: SwitchPorts,
	timing: SwitchTiming = DEFAULT_TIMING,
): Promise<SwitchOutcome> {
	try {
		ports.progress(request === "status" ? "reading primary status" : `switching primary (${request})`);
		const run = await ports.runScript(request);
		if (run.killed || run.code !== 0) {
			const why = run.killed ? "switch-primary.sh was stopped (timeout)" : `switch-primary.sh exited ${run.code}`;
			return { kind: "failed", stage: "script", message: `${why}:\n${failureTail(run.stdout, run.stderr)}` };
		}
		if (request === "status") return { kind: "status", text: run.stdout.trim() };

		const report = parseSwitchReport(run.stdout);
		if (!report.ok) return { kind: "failed", stage: "report", message: `${report.error}:\n${failureTail(run.stdout, "")}` };

		const served = await waitUntilServed(report.value.servedId, ports, timing);
		if (!served.ok) return { kind: "failed", stage: "serve", message: served.error };

		const model = await ports.selectModel(report.value.servedId);
		if (!model.ok) return { kind: "failed", stage: "model", message: model.error };

		return {
			kind: "switched",
			primary: report.value.primary,
			model: model.value,
			unchanged: report.value.unchanged,
			waitedMs: served.value,
		};
	} finally {
		ports.progress(undefined);
	}
}
