/**
 * monitor: run a command in the background and deliver its completion to the session.
 *
 * The `monitor` tool spawns `bash -c <command>` (through a wrapper that records the
 * exit code) in its own process group, journals the monitor into the session, and
 * returns immediately — the turn ends and the session stays interactive. When the
 * command exits, the extension injects a message with the exit code and the tail of
 * the output (steering the current turn or triggering one if idle), so the model can
 * act on a finished CI run, build, or wait without anyone prompting.
 *
 * The journal is the durable state: a session that reloads or resumes re-adopts
 * running monitors by pid — verifying identity first, because a bare pid is only a
 * handle to whatever process the OS parked there (the wrapper's argv carries a
 * per-monitor marker that survives as long as the wrapper does). Children
 * deliberately outlive session shutdown; the journal is what makes that safe.
 */
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, fstatSync, openSync, readSync, readFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentToolResult, ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
	MAX_ACTIVE_MONITORS,
	MONITOR_CUSTOM_TYPE,
	MONITOR_STATUS_CUSTOM_TYPE,
	MONITOR_WRAPPER,
	READOPT_POLL_MS,
	TAIL_READ_BYTES,
	classifyProbe,
	createMonitorSpec,
	decideSpawn,
	exitCodeLabel,
	formatCompletion,
	formatMissedCompletion,
	formatMonitorList,
	parseExitCodeFile,
	parseMonitorJournalData,
	parseMonitorStatusData,
	projectMonitors,
	tailOf,
	monitorArgvMarker,
	type MonitorIdentity,
	type MonitorSpec,
	type SpawnRefusalReason,
} from "./state.js";

/** A monitor this instance tracks: either one it spawned (owning the child handle)
 * or one adopted from the journal (polling the pid). The union keeps the two
 * ownership modes from blurring. */
type RunningMonitor =
	| Readonly<{ kind: "owned"; spec: MonitorSpec; child: ChildProcess }>
	| Readonly<{ kind: "adopted"; spec: MonitorSpec; timer: ReturnType<typeof setInterval> }>;

const specOf = (entry: RunningMonitor): MonitorSpec => entry.spec;

/** Tool result details: the started monitor's identity, or undefined on a refusal. */
type MonitorToolDetails = Readonly<{ monitorId: string; pid: number }> | undefined;

const isPidAlive = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
};

/** Identity probe: a live pid belongs to this monitor only while the process at
 * that pid still carries the monitor's argv marker. After the monitor exits and
 * the OS recycles the pid, the holder's argv lacks the marker, so a reused pid
 * is classified as ended-while-away instead of adopted. A failed probe (ps
 * unusable) is "unknown" — never evidence that the monitor ended. */
const probeMonitorIdentity = (pid: number, id: string): MonitorIdentity => {
	const probe = spawnSync("ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" });
	return classifyProbe(probe.status, probe.stdout ?? "", id);
};

const readExitCode = (codePath: string): number | null => {
	try {
		return parseExitCodeFile(readFileSync(codePath, "utf8"));
	} catch {
		return null;
	}
};

/** The completion tail via a positioned read: at most the last TAIL_READ_BYTES of
 * the log, never the whole file — a multi-hundred-MB CI log costs one small read. */
const readTail = (logPath: string): string => {
	let fd = -1;
	try {
		fd = openSync(logPath, "r");
		const size = fstatSync(fd).size;
		const start = Math.max(0, size - TAIL_READ_BYTES);
		const buffer = Buffer.alloc(size - start);
		readSync(fd, buffer, 0, buffer.length, start);
		return tailOf(buffer.toString("utf8"));
	} catch {
		return "";
	} finally {
		if (fd >= 0) closeSync(fd);
	}
};

const removeFiles = (spec: MonitorSpec): void => {
	try {
		unlinkSync(spec.logPath);
	} catch {
		// already gone
	}
	try {
		unlinkSync(spec.codePath);
	} catch {
		// already gone
	}
};

/** Terminate the monitor's whole process tree: the spawn is detached, so the
 * negative pid names the monitor's own process group. ESRCH means it is already
 * gone. On any other group-kill failure it retries the wrapper pid alone — which
 * may leave the rest of the tree running — and surfaces that: a fallback success
 * returns the partial-termination note, a fallback failure the kill error. */
const killMonitorTree = (pid: number): string | undefined => {
	try {
		process.kill(-pid, "SIGTERM");
		return undefined;
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code === "ESRCH") return undefined;
		try {
			process.kill(pid, "SIGTERM");
			return `the monitor's process group could not be signalled (${code}); only the wrapper was terminated directly — its descendants may survive`;
		} catch (fallbackError) {
			return `could not terminate the monitor's process tree: ${(fallbackError as Error).message}`;
		}
	}
};

export default function (pi: ExtensionAPI) {
	/** Live monitors owned or adopted by this extension instance. */
	const running = new Map<string, RunningMonitor>();
	/** Monitor ids whose completion (or cancellation) this instance has reported;
	 * guards adoption against a second session_start racing the journal write. */
	const reported = new Set<string>();
	/** Session context captured at session_start for footer status updates; cleared on shutdown. */
	let sessionCtx: ExtensionContext | undefined;

	const updateStatus = (): void => {
		if (!sessionCtx?.hasUI) return;
		const names = [...running.values()].map((entry) => specOf(entry).name);
		try {
			sessionCtx.ui.setStatus("monitor", names.length > 0 ? `${names.length} running: ${names.join(", ")}` : undefined);
		} catch {
			// status surface unavailable (e.g. mid-replacement); the shutdown handler clears us first
		}
	};

	const injectCompletion = (content: string): void => {
		pi.sendMessage({ customType: "monitor", content, display: true }, { deliverAs: "steer", triggerTurn: true });
	};

	/** One completion report: read the recorded exit code and output tail, remove the
	 * sidecar files, journal the finish, and deliver the message. */
	const reportCompletion = (spec: MonitorSpec, missed: boolean, cause?: string): void => {
		reported.add(spec.id);
		const exitCode = readExitCode(spec.codePath);
		const tail = readTail(spec.logPath);
		removeFiles(spec);
		pi.appendEntry(MONITOR_CUSTOM_TYPE, {
			kind: "finished",
			id: spec.id,
			name: spec.name,
			exitCode,
			finishedAt: Date.now(),
		});
		injectCompletion(missed ? formatMissedCompletion(spec.name, exitCode, tail) : formatCompletion(spec.name, exitCode, tail, cause));
	};

	/** Completion for a monitor this instance owns. */
	const completeMonitor = (id: string): void => {
		const entry = running.get(id);
		if (!entry) return;
		running.delete(id);
		if (entry.kind === "adopted") clearInterval(entry.timer);
		reportCompletion(entry.spec, false);
		updateStatus();
	};

	const cancelMonitor = (id: string): { ok: true; note?: string } | { ok: false } => {
		const entry = running.get(id);
		if (!entry) return { ok: false };
		running.delete(id);
		reported.add(id);
		const spec = entry.spec;
		if (entry.kind === "adopted") clearInterval(entry.timer);
		// Identity gate: never signal a pid whose holder lost the monitor's marker,
		// and never treat a failed probe as license to signal either — an unverified
		// pid stays unsignalled, with the reason surfaced either way.
		let note: string | undefined;
		// A dead pid maps to "own": there is no live holder to mis-signal, and
		// killMonitorTree's ESRCH arm already treats it as gone.
		const identity = isPidAlive(spec.pid) ? probeMonitorIdentity(spec.pid, spec.id) : "own";
		if (identity === "foreign") {
			note = "the recorded pid no longer carries this monitor's identity; nothing was signalled";
		} else if (identity === "unknown") {
			note = "the monitor's identity could not be verified (the ps probe failed); nothing was signalled";
		} else {
			const killError = killMonitorTree(spec.pid);
			if (killError) note = killError;
		}
		pi.appendEntry(MONITOR_CUSTOM_TYPE, { kind: "cancelled", id, name: spec.name, cancelledAt: Date.now() });
		removeFiles(spec);
		updateStatus();
		return { ok: true, note };
	};

	/** Completion of an adopted monitor: drop it from the map, clear the poller,
	 * report with the given missed wording. */
	const finishAdopted = (spec: MonitorSpec, missed: boolean): void => {
		const entry = running.get(spec.id);
		if (entry) {
			running.delete(spec.id);
			if (entry.kind === "adopted") clearInterval(entry.timer);
		}
		reportCompletion(spec, missed);
		updateStatus();
	};

	const adoptMonitor = (spec: MonitorSpec): void => {
		const identity = isPidAlive(spec.pid) ? probeMonitorIdentity(spec.pid, spec.id) : "foreign";
		if (identity === "foreign") {
			// Dead, or the pid was recycled: the probe ran and the marker is gone, so
			// the monitor ended while pi was away.
			reportCompletion(spec, true);
			updateStatus();
			return;
		}
		// "own" is ours to watch; "unknown" (the ps probe failed) keeps watching too —
		// a wrong adoption self-corrects on the next tick, which re-verifies identity.
		// Poll the pid and re-verify identity each tick: a post-adoption pid reuse
		// looks alive forever to a bare liveness check but fails the marker check,
		// while a failed probe reads as unknown, not as an exit.
		// unref'd so one-shot runs are not held open by the poller alone.
		const timer: ReturnType<typeof setInterval> = setInterval(() => {
			if (!isPidAlive(spec.pid)) {
				// Observed exit between polls: the sidecar carries the true code.
				finishAdopted(spec, false);
				return;
			}
			if (probeMonitorIdentity(spec.pid, spec.id) === "foreign") {
				// The pid was recycled mid-watch: the exit went unnoticed.
				finishAdopted(spec, true);
			}
		}, READOPT_POLL_MS);
		timer.unref();
		running.set(spec.id, { kind: "adopted", spec, timer });
	};

	pi.registerEntryRenderer(MONITOR_CUSTOM_TYPE, (entry, _options, theme) => {
		const data = parseMonitorJournalData(entry.data);
		const label = !data
			? "(monitor)"
			: data.kind === "started"
				? `▶ monitor '${data.spec.name}' started (pid ${data.spec.pid})`
				: data.kind === "finished"
					? `✓ monitor '${data.name}' finished (${exitCodeLabel(data.exitCode)})`
					: `✗ monitor '${data.name}' cancelled`;
		return new Text(data && data.kind === "started" ? label : theme.fg("dim", label));
	});

	pi.registerEntryRenderer(MONITOR_STATUS_CUSTOM_TYPE, (entry) => {
		const lines = parseMonitorStatusData(entry.data);
		return new Text(lines ? lines.join("\n") : "no monitors on record");
	});

	const refusalText = (name: string, reason: SpawnRefusalReason): string => {
		switch (reason) {
			case "invalid-name":
				return `Refused: '${name}' is not a valid monitor name (letters, digits, '.', '_', '-', at most 64 characters).`;
			case "empty-command":
				return "Refused: the monitor command is empty.";
			case "duplicate-name":
				return `A monitor named '${name}' is already running. Cancel it first with monitor_cancel or pick another name.`;
			case "cap-reached":
				return `Refused: the monitor cap (${MAX_ACTIVE_MONITORS}) is reached. Cancel one first (/monitors lists them).`;
			default: {
				const unreachable: never = reason;
				return unreachable;
			}
		}
	};

	pi.registerTool({
		name: "monitor",
		label: "Monitor",
		description:
			"Start a long-running command in the background (CI watch, build, deploy, poll loop) and return immediately. " +
			"The session stays interactive; when the command exits you receive a message with its exit code and the tail of its output. " +
			"The command runs under bash and must terminate on its own. Do not use this for commands whose result you need in this turn — use bash for those.",
		parameters: Type.Object({
			name: Type.String({ description: "Short unique slug for this monitor, e.g. 'ci' or 'build'" }),
			command: Type.String({ description: "Shell command to watch; it must terminate on its own" }),
		}),
		async execute(_toolCallId, params): Promise<AgentToolResult<MonitorToolDetails>> {
			const { name, command } = params;
			const active = [...running.values()].map((entry) => entry.spec);
			const decision = decideSpawn(active, name, command);
			if (decision.kind === "refused") {
				return { content: [{ type: "text", text: refusalText(name, decision.reason) }], details: undefined };
			}
			const id = randomUUID();
			const logPath = join(tmpdir(), `pi-monitor-${id}.log`);
			const codePath = join(tmpdir(), `pi-monitor-${id}.code`);
			let fd = -1;
			try {
				fd = openSync(logPath, "w");
			} catch (error) {
				return { content: [{ type: "text", text: `Could not create the monitor log file: ${(error as Error).message}` }], details: undefined };
			}
			// detached: true gives the wrapper its own process group, so cancel can
			// terminate the command's whole tree. The argv marker (bash's $0) is the
			// identity a later session verifies before trusting the pid. unref'd so a
			// one-shot run is not held open by the child.
			let child: ChildProcess;
			try {
				child = spawn("bash", ["-c", MONITOR_WRAPPER, monitorArgvMarker(id)], {
					detached: true,
					stdio: ["ignore", fd, fd],
					env: { ...process.env, PI_MONITOR_COMMAND: command, PI_MONITOR_CODE_PATH: codePath },
				});
			} catch (error) {
				closeSync(fd);
				return { content: [{ type: "text", text: `Could not start the monitor: ${(error as Error).message}` }], details: undefined };
			}
			closeSync(fd);
			// Attach the error handler before anything can return: a spawn failure that
			// surfaces asynchronously must not escape as an uncaught exception.
			child.on("error", (error) => completeMonitorWithError(id, error));
			child.unref();
			if (child.pid === undefined) {
				return { content: [{ type: "text", text: "Could not start the monitor: the process has no pid." }], details: undefined };
			}
			const spec = createMonitorSpec({ id, name, command, pid: child.pid, logPath, codePath, startedAt: Date.now() });
			if (!spec) {
				return { content: [{ type: "text", text: "Refused: the monitor spec failed validation." }], details: undefined };
			}
			pi.appendEntry(MONITOR_CUSTOM_TYPE, { kind: "started", spec });
			child.on("exit", () => completeMonitor(id));
			running.set(id, { kind: "owned", spec, child });
			updateStatus();
			return {
				content: [{
					type: "text",
					text: `Monitor '${name}' started (pid ${child.pid}). It runs in the background; when it exits you will get its exit code and the last 4 KB of output here. Continue with other work in the meantime.`,
				}],
				details: { monitorId: id, pid: child.pid },
			};
		},
	});

	/** A failed spawn never ran the wrapper, so there is no exit event: complete with
	 * the error as the recorded cause (sidecars absent → terminated, no output). */
	const completeMonitorWithError = (id: string, error: Error): void => {
		const entry = running.get(id);
		if (!entry) return;
		running.delete(id);
		reportCompletion(entry.spec, false, `spawn failed: ${error.message}`);
		updateStatus();
	};

	pi.registerTool({
		name: "monitor_cancel",
		label: "Cancel Monitor",
		description: "Cancel a running background monitor by name. The command's process is terminated; the completion message is not sent.",
		parameters: Type.Object({
			name: Type.String({ description: "Name of the monitor to cancel" }),
		}),
		async execute(_toolCallId, params) {
			const found = [...running.entries()].find(([, entry]) => specOf(entry).name === params.name);
			if (!found) {
				return { content: [{ type: "text", text: `No active monitor named '${params.name}'. /monitors lists the monitors on record.` }], details: {} };
			}
			const result = cancelMonitor(found[0]);
			const suffix = result.ok && result.note ? ` (${result.note})` : "";
			return { content: [{ type: "text", text: `Monitor '${params.name}' cancelled.${suffix}` }], details: {} };
		},
	});

	pi.registerCommand("monitors", {
		description: "List background monitors, or cancel one with '/monitors cancel <name>'",
		handler: async (args, ctx) => {
			const parts = args.trim().split(/\s+/).filter((part) => part.length > 0);
			if (parts[0] === "cancel") {
				const name = parts.slice(1).join(" ");
				const found = [...running.entries()].find(([, entry]) => specOf(entry).name === name);
				if (!found) {
					if (ctx.hasUI) ctx.ui.notify(`No active monitor named '${name}'`, "warning");
					return;
				}
				const result = cancelMonitor(found[0]);
				// Same truth as the monitor_cancel tool path: surface the outcome note
				// (identity gate or kill failure) instead of an unconditional success.
				if (ctx.hasUI) ctx.ui.notify(`Monitor '${name}' cancelled${result.ok && result.note ? ` (${result.note})` : ""}`, "info");
				return;
			}
			const lines = formatMonitorList(projectMonitors(ctx.sessionManager.getEntries()), Date.now());
			pi.appendEntry(MONITOR_STATUS_CUSTOM_TYPE, { lines });
			if (ctx.hasUI) ctx.ui.notify(lines.length > 0 ? `${lines.length} monitor(s) on record` : "No monitors on record", "info");
		},
	});

	pi.on("session_start", (_event, ctx) => {
		sessionCtx = ctx;
		// Re-adopt unfinished monitors from the journal. Idempotent: ids already live
		// or already reported are skipped, so repeat emissions adopt nothing twice.
		const projection = projectMonitors(ctx.sessionManager.getEntries());
		for (const [id, state] of projection) {
			if (state.kind !== "running" || running.has(id) || reported.has(id)) continue;
			adoptMonitor(state.spec);
		}
		updateStatus();
	});

	pi.on("session_shutdown", () => {
		// Children keep running by design (a CI watch outliving a session switch is the
		// point); the journal lets a future session re-adopt them. This instance only
		// drops its handles so no callback fires against a stale runtime, and clears
		// its footer label so a stale 'N running' text cannot outlive the monitors.
		if (sessionCtx?.hasUI) {
			try {
				sessionCtx.ui.setStatus("monitor", undefined);
			} catch {
				// status surface already gone
			}
		}
		for (const [, entry] of running) {
			if (entry.kind === "adopted") clearInterval(entry.timer);
			else entry.child.removeAllListeners();
		}
		running.clear();
		sessionCtx = undefined;
	});
}
