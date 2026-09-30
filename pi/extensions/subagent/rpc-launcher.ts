import { spawn } from "node:child_process";
import type { Message } from "@earendil-works/pi-ai";
import {
	LOOM_EMISSION_READINESS_COMMAND,
	type EmissionRpcDirective,
	type ReadinessClient,
	type ReadinessCommand,
	type ReadinessState,
} from "./loom-launch-port.js";

// A real Pi child can spend 20s reaching get_state while loading the whole Loom graph.
// Bound the full startup gate at 45s to leave headroom for discovery, readiness, and model binding.
const DEFAULT_READINESS_TIMEOUT_MS = 45_000;
const MAX_RPC_LINE_BYTES = 1024 * 1024;
// RPC-mode children stream every event — including per-delta envelopes for
// thinking-heavy models (a thinking-high reviewer routinely produces tens of
// thousands of delta lines). The transcript adapter consumes only
// message_end/tool_result_end records; the deltas are transport noise that
// still count here. The cap must bound a runaway child, not a normal long
// review: 16 MiB killed real wave-gate reviewers mid-flight (every
// qualified-local child died at exactly this cap), so the budget is 256 MiB.
const MAX_RPC_TOTAL_BYTES = 256 * 1024 * 1024;
const MAX_STDERR_BYTES = 64 * 1024;
const KILL_GRACE_MS = 1_000;
const STREAM_ACCOUNTING_TOP = 5;

/**
 * Per-record-type stream accounting for the total-byte cap diagnostic.
 *
 * The cap kills runaway children without telling the operator WHERE the bytes
 * went, and the transcript that could have shown it is discarded with the
 * process. Accounting at the parsed-record boundary (parsed lines only — the
 * final unterminated chunk is bounded by MAX_RPC_LINE_BYTES and excluded)
 * turns a bare "exceeded" into an attributable diagnosis: which event types,
 * how many records, how many bytes. Pure formatter over the map; the map is
 * only written in the transport path and only read when the transport fails.
 */
type StreamTypeAccounting = Readonly<{ count: number; bytes: number }>;

const streamTypeKey = (event: RpcRecord): string =>
	typeof event.type === "string" ? event.type : "<untyped>";

const accountStreamRecord = (
	accounting: Map<string, StreamTypeAccounting>,
	typeKey: string,
	bytes: number,
): void => {
	const current = accounting.get(typeKey) ?? { count: 0, bytes: 0 };
	accounting.set(typeKey, { count: current.count + 1, bytes: current.bytes + bytes });
};

const describeStreamAccounting = (accounting: ReadonlyMap<string, StreamTypeAccounting>): string => {
	const ranked = [...accounting.entries()]
		.map(([type, { count, bytes }]) => ({ type, count, bytes }))
		.sort((a, b) => b.bytes - a.bytes)
		.slice(0, STREAM_ACCOUNTING_TOP);
	if (ranked.length === 0) return "no parsed records";
	return ranked
		.map(({ type, count, bytes }) => `${type}: ${count} records/${(bytes / (1024 * 1024)).toFixed(1)} MiB`)
		.join(", ");
};

type RpcRecord = Record<string, unknown>;

type RpcFailureKind = "aborted" | "spawn" | "protocol" | "readiness" | "child";

export type RpcLaunchFailurePhase = "before-task-prompt" | "task-prompt-sent";

export type RpcLaunchOutcome =
	| Readonly<{ ok: true; stderr: string }>
	| Readonly<{
		ok: false;
		kind: RpcFailureKind;
		phase: RpcLaunchFailurePhase;
		reason: string;
		stderr: string;
		protocolErrors?: readonly string[];
	}>;

export type RpcLaunchInput = Readonly<{
	command: string;
	args: readonly string[];
	cwd: string;
	env: NodeJS.ProcessEnv;
	task: string;
	directive: EmissionRpcDirective;
	signal?: AbortSignal;
	readinessTimeoutMs?: number;
	onMessage: (message: Message) => void;
}>;

type PendingRequest = Readonly<{
	command: string;
	resolve: (response: RpcRecord) => void;
	reject: (error: Error) => void;
}>;

type PendingReadinessEntry = Readonly<{
	resolve: (entry: unknown) => void;
	reject: (error: Error) => void;
	timer: ReturnType<typeof setTimeout>;
}>;

const isRecord = (value: unknown): value is RpcRecord =>
	typeof value === "object" && value !== null && !Array.isArray(value);

const errorMessage = (error: unknown): string => error instanceof Error ? error.message : String(error);

function failure(
	kind: RpcFailureKind,
	phase: RpcLaunchFailurePhase,
	reason: string,
	stderr: string,
	protocolErrors: readonly string[] = [],
): RpcLaunchOutcome {
	return Object.freeze({
		ok: false as const,
		kind,
		phase,
		reason,
		stderr,
		...(protocolErrors.length > 0 ? { protocolErrors: Object.freeze([...protocolErrors]) } : {}),
	});
}

function boundedAppend(current: string, addition: string, maxBytes: number): string {
	const combined = current + addition;
	const bytes = Buffer.byteLength(combined);
	if (bytes <= maxBytes) return combined;
	return Buffer.from(combined).subarray(bytes - maxBytes).toString("utf8");
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
		timer.unref?.();
		promise.then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(error) => {
				clearTimeout(timer);
				reject(error);
			},
		);
	});
}

function responseData(response: RpcRecord, command: string): unknown {
	if (response.success !== true) {
		throw new Error(`${command} refused: ${typeof response.error === "string" ? response.error : "unknown error"}`);
	}
	return response.data;
}

function parseCommands(data: unknown): readonly ReadinessCommand[] {
	if (!isRecord(data) || !Array.isArray(data.commands)) throw new Error("get_commands returned an invalid response");
	const commands = data.commands.flatMap((value): ReadinessCommand[] => {
		if (!isRecord(value) || typeof value.name !== "string") return [];
		return [{
			name: value.name,
			...(typeof value.description === "string" ? { description: value.description } : {}),
			...(typeof value.source === "string" ? { source: value.source } : {}),
			...(typeof value.path === "string" ? { path: value.path } : {}),
		}];
	});
	return Object.freeze(commands);
}

function parseState(data: unknown): ReadinessState {
	if (!isRecord(data) || !(data.model === null || isRecord(data.model))) {
		throw new Error("get_state returned an invalid response");
	}
	return data as ReadinessState;
}

function stateHasModel(state: ReadinessState, provider: string, id: string): boolean {
	return state.model !== null && state.model.provider === provider && state.model.id === id;
}

export async function runRpcAgent(input: RpcLaunchInput): Promise<RpcLaunchOutcome> {
	if (input.signal?.aborted) {
		return failure("aborted", "before-task-prompt", "Subagent was aborted before it started", "");
	}

	let stderr = "";
	let taskPromptSent = false;
	const failurePhase = (): RpcLaunchFailurePhase =>
		taskPromptSent ? "task-prompt-sent" : "before-task-prompt";
	const protocolErrors: string[] = [];
	let totalBytes = 0;
	const streamAccounting = new Map<string, StreamTypeAccounting>();
	let stdoutBuffer = Buffer.alloc(0);
	let requestCounter = 0;
	let intentionalShutdown = false;
	let readinessInvocations = 0;
	let readinessObserved = false;
	let modelSetToExpectedAfterReadiness = false;
	let exactRouteStateObserved = false;
	let pendingReadinessEntry: PendingReadinessEntry | null = null;
	const readinessTimeoutMs = input.readinessTimeoutMs ?? DEFAULT_READINESS_TIMEOUT_MS;
	const pending = new Map<string, PendingRequest>();

	let resolveSettled!: () => void;
	let rejectSettled!: (error: Error) => void;
	const agentSettled = new Promise<void>((resolve, reject) => {
		resolveSettled = resolve;
		rejectSettled = reject;
	});
	// The transport can fail during startup, before the settled phase is awaited.
	// Observe that early rejection immediately while preserving it for later awaits.
	void agentSettled.catch(() => {});

	let resolveExit!: (exit: Readonly<{ code: number | null; signal: NodeJS.Signals | null }>) => void;
	const exited = new Promise<Readonly<{ code: number | null; signal: NodeJS.Signals | null }>>((resolve) => {
		resolveExit = resolve;
	});

	let proc: ReturnType<typeof spawn>;
	try {
		proc = spawn(input.command, [...input.args], {
			cwd: input.cwd,
			env: input.env,
			shell: false,
			stdio: ["pipe", "pipe", "pipe"],
		});
	} catch (error) {
		return failure("spawn", failurePhase(), `Failed to spawn subagent process: ${errorMessage(error)}`, stderr);
	}

	let fatalError: Error | null = null;
	const cancelReadinessEntryWait = (error: Error): void => {
		if (!pendingReadinessEntry) return;
		clearTimeout(pendingReadinessEntry.timer);
		const waiter = pendingReadinessEntry;
		pendingReadinessEntry = null;
		waiter.reject(error);
	};
	const waitForReadinessEntry = (): Promise<unknown> => {
		if (pendingReadinessEntry) return Promise.reject(new Error("A readiness entry wait is already active"));
		return new Promise<unknown>((resolve, reject) => {
			const timer = setTimeout(() => {
				pendingReadinessEntry = null;
				reject(new Error(
					`/${LOOM_EMISSION_READINESS_COMMAND} entry_appended timed out after ${readinessTimeoutMs}ms`,
				));
			}, readinessTimeoutMs);
			timer.unref?.();
			pendingReadinessEntry = { resolve, reject, timer };
		});
	};
	const failTransport = (error: Error, raw?: string): void => {
		if (fatalError) return;
		fatalError = error;
		if (raw && protocolErrors.length < 3) protocolErrors.push(raw.slice(0, 500));
		for (const request of pending.values()) request.reject(error);
		pending.clear();
		cancelReadinessEntryWait(error);
		rejectSettled(error);
	};

	const handleRecord = (line: Buffer): void => {
		if (line.length > MAX_RPC_LINE_BYTES) {
			failTransport(new Error(`RPC record exceeded ${MAX_RPC_LINE_BYTES} bytes`));
			return;
		}
		const normalized = line.length > 0 && line[line.length - 1] === 0x0d ? line.subarray(0, -1) : line;
		if (normalized.length === 0) return;
		const text = normalized.toString("utf8");
		let event: RpcRecord;
		try {
			const parsed: unknown = JSON.parse(text);
			if (!isRecord(parsed)) throw new Error("record is not an object");
			event = parsed;
		} catch {
			failTransport(new Error("Subagent emitted malformed RPC JSON output"), text);
			return;
		}
		accountStreamRecord(streamAccounting, streamTypeKey(event), line.length + 1);

		if (event.type === "response") {
			if (typeof event.id !== "string") {
				failTransport(new Error("RPC response omitted its correlation id"), text);
				return;
			}
			const request = pending.get(event.id);
			if (!request) {
				failTransport(new Error(`RPC response used unknown id ${event.id}`), text);
				return;
			}
			pending.delete(event.id);
			if (event.command !== request.command) {
				request.reject(new Error(`RPC response command mismatch: expected ${request.command}, received ${String(event.command)}`));
				return;
			}
			request.resolve(event);
			return;
		}

		if (
			event.type === "entry_appended" && isRecord(event.entry) &&
			event.entry.customType === LOOM_EMISSION_READINESS_COMMAND && pendingReadinessEntry
		) {
			clearTimeout(pendingReadinessEntry.timer);
			const waiter = pendingReadinessEntry;
			pendingReadinessEntry = null;
			waiter.resolve(event.entry);
		}
		if ((event.type === "message_end" || event.type === "tool_result_end") && isRecord(event.message)) {
			input.onMessage(event.message as Message);
		}
		if (event.type === "agent_settled") resolveSettled();
	};

	proc.stdout.on("data", (chunk: Buffer | string) => {
		if (fatalError) return;
		const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
		totalBytes += bytes.length;
		if (totalBytes > MAX_RPC_TOTAL_BYTES) {
			failTransport(new Error(
				`RPC output exceeded ${MAX_RPC_TOTAL_BYTES} bytes (stream accounting: ${describeStreamAccounting(streamAccounting)})`,
			));
			return;
		}
		stdoutBuffer = Buffer.concat([stdoutBuffer, bytes]);
		while (true) {
			const newline = stdoutBuffer.indexOf(0x0a);
			if (newline < 0) break;
			const line = stdoutBuffer.subarray(0, newline);
			stdoutBuffer = stdoutBuffer.subarray(newline + 1);
			handleRecord(line);
			if (fatalError) return;
		}
		if (stdoutBuffer.length > MAX_RPC_LINE_BYTES) {
			failTransport(new Error(`RPC record exceeded ${MAX_RPC_LINE_BYTES} bytes`));
		}
	});
	proc.stderr.on("data", (chunk: Buffer | string) => {
		stderr = boundedAppend(stderr, chunk.toString(), MAX_STDERR_BYTES);
	});
	proc.on("error", (error) => failTransport(new Error(`Failed to spawn subagent process: ${error.message}`)));
	proc.on("close", (code, childSignal) => {
		if (stdoutBuffer.length > 0 && !fatalError) {
			failTransport(new Error("RPC output ended with an unterminated JSON record"), stdoutBuffer.toString("utf8"));
		}
		resolveExit({ code, signal: childSignal });
		if (!intentionalShutdown && !fatalError) {
			failTransport(new Error(
				childSignal
					? `Subagent process terminated by signal ${childSignal}`
					: `Subagent process exited before agent_settled (code ${code ?? 1})`,
			));
		}
	});

	const abortError = new Error("Subagent was aborted");
	const abortPromise = new Promise<never>((_resolve, reject) => {
		if (!input.signal) return;
		const abort = () => reject(abortError);
		if (input.signal.aborted) abort();
		else input.signal.addEventListener("abort", abort, { once: true });
	});

	const request = (
		command: string,
		fields: RpcRecord = {},
		beforeWrite?: () => void,
	): Promise<RpcRecord> => {
		if (fatalError) return Promise.reject(fatalError);
		const id = `subagent-${++requestCounter}`;
		const payload = JSON.stringify({ id, type: command, ...fields });
		if (Buffer.byteLength(payload) > MAX_RPC_LINE_BYTES) {
			return Promise.reject(new Error(`RPC command exceeded ${MAX_RPC_LINE_BYTES} bytes`));
		}
		return new Promise<RpcRecord>((resolve, reject) => {
			pending.set(id, { command, resolve, reject });
			beforeWrite?.();
			proc.stdin.write(`${payload}\n`, (error) => {
				if (!error) return;
				pending.delete(id);
				reject(error);
			});
		});
	};

	const readinessClient: ReadinessClient = Object.freeze({
		getCommands: async () => parseCommands(responseData(await request("get_commands"), "get_commands")),
		invokeReadiness: async () => {
			readinessInvocations++;
			if (readinessInvocations > 1) throw new Error("readiness command may be invoked only once per child");
			const entryPromise = waitForReadinessEntry();
			void entryPromise.catch(() => {});
			try {
				responseData(
					await request("prompt", { message: `/${LOOM_EMISSION_READINESS_COMMAND}` }),
					LOOM_EMISSION_READINESS_COMMAND,
				);
				const entry = await entryPromise;
				readinessObserved = true;
				return Object.freeze([entry]);
			} catch (error) {
				cancelReadinessEntryWait(error instanceof Error ? error : new Error(String(error)));
				throw error;
			}
		},
		setModel: async (provider, modelId) => {
			responseData(await request("set_model", { provider, modelId }), "set_model");
			modelSetToExpectedAfterReadiness = readinessObserved &&
				provider === input.directive.expectedProvider && modelId === input.directive.expectedModel;
			exactRouteStateObserved = false;
		},
		getState: async () => {
			const state = parseState(responseData(await request("get_state"), "get_state"));
			exactRouteStateObserved = modelSetToExpectedAfterReadiness &&
				stateHasModel(state, input.directive.expectedProvider, input.directive.expectedModel);
			return state;
		},
	});

	const stopChild = async (): Promise<void> => {
		intentionalShutdown = true;
		if (proc.exitCode !== null || proc.signalCode !== null) {
			await exited;
			return;
		}
		proc.kill("SIGTERM");
		const force = setTimeout(() => {
			if (proc.exitCode === null && proc.signalCode === null) proc.kill("SIGKILL");
		}, KILL_GRACE_MS);
		force.unref?.();
		await exited;
		clearTimeout(force);
	};

	try {
		const readiness = async (): Promise<void> => {
			const commands = await readinessClient.getCommands();
			if (!commands.some((command) =>
				command.name === LOOM_EMISSION_READINESS_COMMAND && command.source === "extension")) {
				throw new Error(`Required extension command /${LOOM_EMISSION_READINESS_COMMAND} is unavailable`);
			}
			const verdict = await input.directive.verifyReadiness(readinessClient);
			if (!isRecord(verdict) || typeof verdict.ok !== "boolean") throw new Error("Readiness verifier returned an invalid verdict");
			if (!verdict.ok) throw new Error(verdict.reason || "Readiness verifier refused the child");
			if (readinessInvocations !== 1 || !readinessObserved) {
				throw new Error(`Readiness verifier must invoke /${LOOM_EMISSION_READINESS_COMMAND} exactly once`);
			}
			if (!modelSetToExpectedAfterReadiness) {
				throw new Error(
					`Readiness verifier must select ${input.directive.expectedProvider}/${input.directive.expectedModel} after readiness`,
				);
			}
			if (!exactRouteStateObserved) {
				throw new Error(
					`Readiness verifier must observe exact route ${input.directive.expectedProvider}/${input.directive.expectedModel}`,
				);
			}
		};

		await Promise.race([
			withTimeout(readiness(), readinessTimeoutMs, "Emission readiness"),
			abortPromise,
		]);
		const taskPromptResponse = request("prompt", { message: input.task }, () => {
			taskPromptSent = true;
		});
		responseData(
			await Promise.race([
				withTimeout(taskPromptResponse, readinessTimeoutMs, "Task prompt"),
				abortPromise,
			]),
			"prompt",
		);
		await Promise.race([agentSettled, abortPromise]);
		await stopChild();
		return Object.freeze({ ok: true as const, stderr });
	} catch (error) {
		cancelReadinessEntryWait(error instanceof Error ? error : new Error(String(error)));
		await stopChild();
		const reason = errorMessage(error);
		const phase = failurePhase();
		if (error === abortError || input.signal?.aborted) return failure("aborted", phase, reason, stderr, protocolErrors);
		if (/spawn/i.test(reason)) return failure("spawn", phase, reason, stderr, protocolErrors);
		if (fatalError) return failure("protocol", phase, reason, stderr, protocolErrors);
		const exit = await exited;
		if (exit.signal || (exit.code !== null && exit.code !== 0)) {
			return failure("child", phase, reason, stderr, protocolErrors);
		}
		return failure("readiness", phase, reason, stderr, protocolErrors);
	}
}
