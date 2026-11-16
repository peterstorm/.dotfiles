// Pure monitor state: journal projection, total parsing, spawn decisions, and
// message formatting. No I/O — the extension shell (index.ts) owns processes,
// files, timers and pi calls.

export const MONITOR_CUSTOM_TYPE = "monitor";
export const MONITOR_STATUS_CUSTOM_TYPE = "monitor-status";
/** Concurrent-monitor cap; the tool refuses to start beyond it. */
export const MAX_ACTIVE_MONITORS = 8;
/** Completion messages carry at most this many bytes of the monitor's output. */
export const COMPLETION_TAIL_BYTES = 4096;
/** How many end-of-file bytes the positioned tail read may scan for a line boundary. */
export const TAIL_READ_BYTES = COMPLETION_TAIL_BYTES * 2;
/** How often a re-adopted monitor polls its pid for exit. */
export const READOPT_POLL_MS = 2_000;

/** The bash wrapper every monitor runs: it records the command's exit code so a
 * re-adopting session (which cannot waitpid a pid it no longer holds a handle
 * for) can still report the true code. The command runs in a subshell so an
 * `exit` inside it cannot skip the code write; a failed write exits 255 with no
 * sidecar, so a lost exit code reads as terminated, never as a fabricated one.
 * PI_MONITOR_COMMAND and PI_MONITOR_CODE_PATH come from the spawn environment. */
export const MONITOR_WRAPPER =
	'( eval "$PI_MONITOR_COMMAND" ); code=$?; printf %s "$code" > "$PI_MONITOR_CODE_PATH" || exit 255; exit $code';

/** The wrapper's argv marker (bash $0): the identity anchor that lets a later
 * session verify a live pid still belongs to this monitor and not to whatever
 * process recycled the pid after the monitor exited. */
export const monitorArgvMarker = (id: string): string => `pi-monitor-${id}`;

/** Pure: whether a `ps -o command=` line belongs to the monitor with this id. */
export const commandLineMatchesMarker = (commandLine: string, id: string): boolean =>
	commandLine.includes(monitorArgvMarker(id));

/** Identity of a probed live process: "own" carries the monitor's argv marker,
 * "foreign" is a live pid without it (the pid was recycled), "unknown" means the
 * probe itself failed — which is never evidence that the monitor ended. */
export type MonitorIdentity = "own" | "foreign" | "unknown";

/** Pure: classify a pid probe by its exit status and command line. A non-zero or
 * missing status is "unknown" — indistinguishable from a marker mismatch would be
 * a lie, so the caller keeps watching instead of reporting an ending. */
export const classifyProbe = (status: number | null, commandLine: string, id: string): MonitorIdentity =>
	status === 0 ? (commandLineMatchesMarker(commandLine, id) ? "own" : "foreign") : "unknown";

/** Everything needed to re-adopt a monitor after a reload or session resume. */
export type MonitorSpec = Readonly<{
	id: string;
	name: string;
	command: string;
	pid: number;
	logPath: string;
	codePath: string;
	startedAt: number;
}>;

/** Journal entry payloads under MONITOR_CUSTOM_TYPE. */
export type MonitorJournalData =
	| Readonly<{ kind: "started"; spec: MonitorSpec }>
	| Readonly<{ kind: "finished"; id: string; name: string; exitCode: number | null; finishedAt: number }>
	| Readonly<{ kind: "cancelled"; id: string; name: string; cancelledAt: number }>;

/** Newest-journal-entry state per monitor id. */
export type MonitorRuntimeState =
	| Readonly<{ kind: "running"; spec: MonitorSpec }>
	| Readonly<{ kind: "finished"; name: string; exitCode: number | null }>
	| Readonly<{ kind: "cancelled"; name: string }>;

/** Structured refusal for a monitor start request; the shell renders the text. */
export type SpawnRefusalReason = "invalid-name" | "empty-command" | "duplicate-name" | "cap-reached";
export type SpawnDecision = Readonly<{ kind: "accepted" }> | Readonly<{ kind: "refused"; reason: SpawnRefusalReason }>;

export type SessionEntryShape = Readonly<{ type: string; customType?: string; data?: unknown }>;

const isFiniteInt = (value: unknown): value is number => typeof value === "number" && Number.isInteger(value);

export const isValidMonitorName = (name: string): boolean => /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name);

/** Total: the one exit-code invariant ([0, 255], integer) for sidecar contents.
 * An empty or malformed sidecar is null — an unknown code, never a false green. */
export const parseExitCodeFile = (content: string): number | null => {
	const trimmed = content.trim();
	if (trimmed.length === 0) return null;
	const value = Number(trimmed);
	return isFiniteInt(value) && value >= 0 && value <= 255 ? value : null;
};

/** Pure spawn decision over the active monitors and the request. */
export const decideSpawn = (
	active: readonly MonitorSpec[],
	name: string,
	command: string,
): SpawnDecision => {
	if (!isValidMonitorName(name)) return { kind: "refused", reason: "invalid-name" };
	if (command.trim().length === 0) return { kind: "refused", reason: "empty-command" };
	if (active.some((spec) => spec.name === name)) return { kind: "refused", reason: "duplicate-name" };
	if (active.length >= MAX_ACTIVE_MONITORS) return { kind: "refused", reason: "cap-reached" };
	return { kind: "accepted" };
};

/** Smart constructor: the single gate that produces a validated MonitorSpec. */
export const createMonitorSpec = (fields: {
	id: string;
	name: string;
	command: string;
	pid: number;
	logPath: string;
	codePath: string;
	startedAt: number;
}): MonitorSpec | undefined => {
	const { id, name, command, pid, logPath, codePath, startedAt } = fields;
	if (
		typeof id !== "string" || id.length === 0 ||
		typeof name !== "string" || !isValidMonitorName(name) ||
		typeof command !== "string" || command.length === 0 ||
		!isFiniteInt(pid) || pid <= 0 ||
		typeof logPath !== "string" || logPath.length === 0 ||
		typeof codePath !== "string" || codePath.length === 0 ||
		!isFiniteInt(startedAt)
	) {
		return undefined;
	}
	return { id, name, command, pid, logPath, codePath, startedAt };
};

const parseSpec = (value: unknown): MonitorSpec | undefined => {
	if (typeof value !== "object" || value === null) return undefined;
	return createMonitorSpec(value as Parameters<typeof createMonitorSpec>[0]);
};

/** Total parse of journal data into a monitor record, or undefined when it is not one. */
export const parseMonitorJournalData = (data: unknown): MonitorJournalData | undefined => {
	if (typeof data !== "object" || data === null) return undefined;
	const record = data as Record<string, unknown>;
	if (record.kind === "started") {
		const spec = parseSpec(record.spec);
		return spec ? { kind: "started", spec } : undefined;
	}
	if (record.kind === "finished") {
		const { id, name, exitCode, finishedAt } = record;
		if (typeof id !== "string" || id.length === 0 || typeof name !== "string" || !isValidMonitorName(name) || !isFiniteInt(finishedAt)) {
			return undefined;
		}
		if (!(exitCode === null || (isFiniteInt(exitCode) && exitCode >= 0 && exitCode <= 255))) return undefined;
		return { kind: "finished", id, name, exitCode, finishedAt };
	}
	if (record.kind === "cancelled") {
		const { id, name, cancelledAt } = record;
		if (typeof id !== "string" || id.length === 0 || typeof name !== "string" || !isValidMonitorName(name) || !isFiniteInt(cancelledAt)) {
			return undefined;
		}
		return { kind: "cancelled", id, name, cancelledAt };
	}
	return undefined;
};

/** Total parse of a monitor-status payload into its lines, or undefined. */
export const parseMonitorStatusData = (data: unknown): string[] | undefined => {
	if (typeof data !== "object" || data === null) return undefined;
	const lines = (data as Record<string, unknown>).lines;
	return Array.isArray(lines) && lines.length > 0 && lines.every((line) => typeof line === "string")
		? (lines as string[])
		: undefined;
};

/** Newest entry per monitor id wins; malformed entries are skipped. */
export const projectMonitors = (entries: readonly SessionEntryShape[]): Map<string, MonitorRuntimeState> => {
	const byId = new Map<string, MonitorRuntimeState>();
	for (const entry of entries) {
		if (entry.type !== "custom" || entry.customType !== MONITOR_CUSTOM_TYPE) continue;
		const data = parseMonitorJournalData(entry.data);
		if (!data) continue;
		if (data.kind === "started") byId.set(data.spec.id, { kind: "running", spec: data.spec });
		else if (data.kind === "finished") byId.set(data.id, { kind: "finished", name: data.name, exitCode: data.exitCode });
		else byId.set(data.id, { kind: "cancelled", name: data.name });
	}
	return byId;
};

export const exitCodeLabel = (exitCode: number | null): string => (exitCode === null ? "terminated" : `exit ${exitCode}`);

export const formatCompletion = (name: string, exitCode: number | null, tail: string, cause?: string): string =>
	`Monitor '${name}' finished (${exitCodeLabel(exitCode)}).${cause ? ` (${cause})` : ""}${tail ? `\nLast output:\n${tail}` : ""}`;

export const formatMissedCompletion = (name: string, exitCode: number | null, tail: string): string =>
	`Monitor '${name}' ended while pi was not watching (session restarted or reloaded mid-run; ${exitCodeLabel(exitCode)}).${tail ? `\nLast output:\n${tail}` : ""}`;

/** Last maxBytes of text, cut after the first interior line break of the
 * window; a window without an interior break is returned as-is and may start
 * mid-line. */
export const tailOf = (text: string, maxBytes = COMPLETION_TAIL_BYTES): string => {
	const buffer = Buffer.from(text, "utf8");
	if (buffer.length <= maxBytes) return text;
	const slice = buffer.subarray(buffer.length - maxBytes).toString("utf8");
	const newline = slice.indexOf("\n");
	return newline >= 0 && newline < slice.length - 1 ? slice.slice(newline + 1) : slice;
};

/** /monitors listing: running first (oldest start), then finished and cancelled
 * in first-appearance (start) order. */
export const formatMonitorList = (projection: ReadonlyMap<string, MonitorRuntimeState>, now: number): string[] => {
	const running: Array<{ name: string; pid: number; startedAt: number }> = [];
	const settled: string[] = [];
	for (const state of projection.values()) {
		if (state.kind === "running") running.push({ name: state.spec.name, pid: state.spec.pid, startedAt: state.spec.startedAt });
		else if (state.kind === "finished") settled.push(`✓ ${state.name} — ${exitCodeLabel(state.exitCode)}`);
		else settled.push(`✗ ${state.name} — cancelled`);
	}
	running.sort((a, b) => a.startedAt - b.startedAt);
	const minutes = (startedAt: number): number => Math.max(1, Math.round((now - startedAt) / 60_000));
	return [
		...running.map((m) => `● ${m.name} — running (pid ${m.pid}, ~${minutes(m.startedAt)}m)`),
		...settled,
	];
};
