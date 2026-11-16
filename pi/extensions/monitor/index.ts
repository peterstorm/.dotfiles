/**
 * monitor: run a command in the background and deliver its completion to the session.
 *
 * The `monitor` tool spawns `bash -c <command>` (through a wrapper that records the
 * exit code), journals the monitor into the session, and returns immediately — the
 * turn ends and the session stays interactive. When the command exits, the
 * extension injects a message with the exit code and the tail of the output
 * (steering the current turn or triggering one if idle), so the model can act on a
 * finished CI run, build, or wait without anyone prompting.
 *
 * The journal is the durable state: a session that reloads or resumes re-adopts
 * running monitors by pid (polling, since the ChildProcess handle died with the old
 * extension instance) and completes monitors that ended while pi was away. Children
 * deliberately outlive session shutdown; the journal is what makes that safe.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, openSync, readFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext, ExtensionToolContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
	COMPLETION_TAIL_BYTES,
	MAX_ACTIVE_MONITORS,
	MONITOR_CUSTOM_TYPE,
	MONITOR_STATUS_CUSTOM_TYPE,
	MONITOR_WRAPPER,
	READOPT_POLL_MS,
	exitCodeLabel,
	formatCompletion,
	formatMissedCompletion,
	formatMonitorList,
	isValidMonitorName,
	parseMonitorJournalData,
	projectMonitors,
	tailOf,
	type MonitorSpec,
} from "./state.js";

type RunningMonitor = Readonly<{ spec: MonitorSpec; child?: ChildProcess; timer?: ReturnType<typeof setInterval> }>;

const isPidAlive = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
};

const readExitCode = (codePath: string): number | null => {
	try {
		const code = Number(readFileSync(codePath, "utf8").trim());
		return Number.isInteger(code) && code >= 0 && code <= 255 ? code : null;
	} catch {
		return null;
	}
};

const readTail = (logPath: string): string => {
	try {
		return tailOf(readFileSync(logPath, "utf8"));
	} catch {
		return "";
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

/** The monitor finished and the journal must say so. */
const journalFinished = (pi: ExtensionAPI, spec: MonitorSpec, exitCode: number | null): void => {
	pi.appendEntry(MONITOR_CUSTOM_TYPE, {
		kind: "finished",
		id: spec.id,
		name: spec.name,
		exitCode,
		finishedAt: Date.now(),
	});
};

export default function (pi: ExtensionAPI) {
	/** Live monitors owned or adopted by this extension instance. */
	const running = new Map<string, RunningMonitor>();
	/** Session context captured at session_start for footer status updates; cleared on shutdown. */
	let sessionCtx: ExtensionContext | undefined;

	const updateStatus = (): void => {
		if (!sessionCtx?.hasUI) return;
		const names = [...running.values()].map((m) => m.spec.name);
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
	const reportCompletion = (spec: MonitorSpec, missed: boolean): void => {
		const exitCode = readExitCode(spec.codePath);
		const tail = readTail(spec.logPath);
		removeFiles(spec);
		journalFinished(pi, spec, exitCode);
		injectCompletion(missed ? formatMissedCompletion(spec.name, exitCode, tail) : formatCompletion(spec.name, exitCode, tail));
	};

	/** Completion for a monitor this instance owns. */
	const completeMonitor = (id: string, missed: boolean): void => {
		const entry = running.get(id);
		if (!entry) return;
		running.delete(id);
		if (entry.timer) clearInterval(entry.timer);
		reportCompletion(entry.spec, missed);
		updateStatus();
	};

	/** Completion for a monitor found dead at adoption time (pi was away when it ended).
	 * It never entered the map, so only the report fires. */
	const completeMissedMonitor = (spec: MonitorSpec): void => {
		reportCompletion(spec, true);
	};

	const stopTimer = (entry: RunningMonitor): void => {
		if (entry.timer) clearInterval(entry.timer);
	};

	const cancelMonitor = (id: string): boolean => {
		const entry = running.get(id);
		if (!entry) return false;
		running.delete(id);
		stopTimer(entry);
		if (entry.child) {
			// Detach the exit handlers first: a cancelled monitor journals "cancelled",
			// and its exit event must not run the completion path.
			entry.child.removeAllListeners();
			entry.child.kill("SIGTERM");
		} else {
			try {
				process.kill(entry.spec.pid, "SIGTERM");
			} catch {
				// already gone
			}
		}
		pi.appendEntry(MONITOR_CUSTOM_TYPE, { kind: "cancelled", id, name: entry.spec.name, cancelledAt: Date.now() });
		removeFiles(entry.spec);
		updateStatus();
		return true;
	};

	const adoptMonitor = (spec: MonitorSpec): void => {
		if (isPidAlive(spec.pid)) {
			// Poll the pid: the ChildProcess handle belongs to the instance that spawned
			// it. unref'd so one-shot runs are not held open by the poller alone.
			const timer: ReturnType<typeof setInterval> = setInterval(() => {
				if (isPidAlive(spec.pid)) return;
				const entry = running.get(spec.id);
				if (entry?.timer) clearInterval(entry.timer);
				completeMonitor(spec.id, false);
			}, READOPT_POLL_MS);
			timer.unref();
			running.set(spec.id, { spec, timer });
			return;
		}
		completeMissedMonitor(spec);
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
		const lines = (entry.data as { lines?: unknown }).lines;
		const text = Array.isArray(lines) && lines.every((line) => typeof line === "string") && lines.length > 0
			? (lines as string[]).join("\n")
			: "no monitors on record";
		return new Text(text);
	});

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
		async execute(_toolCallId, params) {
			const { name, command } = params;
			if (!isValidMonitorName(name)) {
				return { content: [{ type: "text", text: `Refused: '${name}' is not a valid monitor name (letters, digits, '.', '_', '-', at most 64 characters).` }], details: {} };
			}
			if (command.trim().length === 0) {
				return { content: [{ type: "text", text: "Refused: the monitor command is empty." }], details: {} };
			}
			const conflict = [...running.values()].find((m) => m.spec.name === name);
			if (conflict) {
				return { content: [{ type: "text", text: `A monitor named '${name}' is already running (pid ${conflict.spec.pid}). Cancel it first with monitor_cancel or pick another name.` }], details: {} };
			}
			if (running.size >= MAX_ACTIVE_MONITORS) {
				return { content: [{ type: "text", text: `Refused: the monitor cap (${MAX_ACTIVE_MONITORS}) is reached. Cancel one first (/monitors lists them).` }], details: {} };
			}
			const id = randomUUID();
			const logPath = join(tmpdir(), `pi-monitor-${id}.log`);
			const codePath = join(tmpdir(), `pi-monitor-${id}.code`);
			let fd = -1;
			try {
				fd = openSync(logPath, "w");
			} catch (error) {
				return { content: [{ type: "text", text: `Could not create the monitor log file: ${(error as Error).message}` }], details: {} };
			}
			let child: ChildProcess;
			try {
				child = spawn("bash", ["-c", MONITOR_WRAPPER], {
					stdio: ["ignore", fd, fd],
					env: { ...process.env, PI_MONITOR_COMMAND: command, PI_MONITOR_CODE_PATH: codePath },
				});
			} catch (error) {
				closeSync(fd);
				return { content: [{ type: "text", text: `Could not start the monitor: ${(error as Error).message}` }], details: {} };
			}
			closeSync(fd);
			if (child.pid === undefined) {
				return { content: [{ type: "text", text: "Could not start the monitor: the process has no pid." }], details: {} };
			}
			const spec: MonitorSpec = { id, name, command, pid: child.pid, logPath, codePath, startedAt: Date.now() };
			pi.appendEntry(MONITOR_CUSTOM_TYPE, { kind: "started", spec });
			child.on("exit", () => completeMonitor(id, false));
			child.on("error", () => completeMonitor(id, false));
			running.set(id, { spec, child });
			updateStatus();
			return {
				content: [{
					type: "text",
					text: `Monitor '${name}' started (pid ${child.pid}). It runs in the background; when it exits you will get its exit code and the last ${COMPLETION_TAIL_BYTES} bytes of output here. Continue with other work in the meantime.`,
				}],
				details: { monitorId: id, pid: child.pid },
			};
		},
	});

	pi.registerTool({
		name: "monitor_cancel",
		label: "Cancel Monitor",
		description: "Cancel a running background monitor by name. The command's process is terminated; the completion message is not sent.",
		parameters: Type.Object({
			name: Type.String({ description: "Name of the monitor to cancel" }),
		}),
		async execute(_toolCallId, params) {
			const found = [...running.entries()].find(([, m]) => m.spec.name === params.name);
			if (!found) {
				return { content: [{ type: "text", text: `No active monitor named '${params.name}'. /monitors lists the monitors on record.` }], details: {} };
			}
			cancelMonitor(found[0]);
			return { content: [{ type: "text", text: `Monitor '${params.name}' cancelled.` }], details: {} };
		},
	});

	pi.registerCommand("monitors", {
		description: "List background monitors, or cancel one with '/monitors cancel <name>'",
		handler: async (args, ctx) => {
			const parts = args.trim().split(/\s+/).filter((part) => part.length > 0);
			if (parts[0] === "cancel") {
				const name = parts.slice(1).join(" ");
				const found = [...running.entries()].find(([, m]) => m.spec.name === name);
				if (!found) {
					if (ctx.hasUI) ctx.ui.notify(`No active monitor named '${name}'`, "warning");
					return;
				}
				cancelMonitor(found[0]);
				if (ctx.hasUI) ctx.ui.notify(`Monitor '${name}' cancelled`, "info");
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
		// in the map are skipped, so repeat session_start emissions adopt nothing twice.
		const projection = projectMonitors(ctx.sessionManager.getEntries());
		for (const [id, state] of projection) {
			if (state.kind !== "running" || running.has(id)) continue;
			adoptMonitor(state.spec);
		}
		updateStatus();
	});

	pi.on("session_shutdown", () => {
		// Children keep running by design (a CI watch outliving a session switch is the
		// point); the journal lets a future session re-adopt them. This instance only
		// drops its handles so no callback fires against a stale runtime.
		for (const [, entry] of running) {
			stopTimer(entry);
			entry.child?.removeAllListeners();
		}
		running.clear();
		sessionCtx = undefined;
	});
}
