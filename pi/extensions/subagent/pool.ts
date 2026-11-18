/**
 * Subagent pool — a process-wide dispatcher over the `subagent` tool's fan-out.
 *
 * Why: a parallel call runs at most MAX_CONCURRENCY children and blocks until every one settles. With
 * more dispatches than slots, a freed slot is only refilled when the whole batch settles, and a retry can
 * only be dispatched after the barrier. The pool keeps every slot busy across calls: a task that settles
 * anywhere frees its slot for the next queued task, immediately.
 *
 * Structure: functional core / imperative shell.
 *   - Pure: PoolState and its transitions (enqueue, planLaunches, settleEntry, abortQueued, cancelQueued,
 *     drainedCall). No I/O, no timers, no randomness. `planLaunches` reserves a slot by moving an entry to
 *     `running` before any launch is awaited, so a reentrant pump cannot exceed the cap.
 *   - Shell: createDispatcher, which sequences the pure transitions around the injected launch effect and
 *     the per-task AbortControllers.
 *
 * Loom interplay (DESIGN-pool.md §3): blocking pool calls are Loom-safe — every launch happens while the
 * tool call is live, so staged emission expectations are consumable and the final tool result is fully
 * settled. Background calls are never Loom-governed (`looksLoomGoverned` refuses fail-closed): Loom
 * settles graph-governed batches from the tool result, so a background snapshot would settle them early.
 */

/** Cap on one pooled call. Loom's `spawn-wave-implementation` names every ready dispatch at once. */
export const MAX_POOL_TASKS = 64;

/** Default slot count; matches the engines on desktop (8 lanes). Overridable for other engines. */
export const DEFAULT_POOL_CONCURRENCY = 8;

export type Result<T, E> =
	| Readonly<{ ok: true; value: T }>
	| Readonly<{ ok: false; error: E }>;

const ok = <T>(value: T): Result<T, never> => ({ ok: true, value });
const err = <E>(error: E): Result<never, E> => ({ ok: false, error });

/** How a launched task ended, from the dispatcher's point of view. */
export type PoolOutcome<R> =
	| Readonly<{ kind: "completed"; result: R }>
	/** A process-level failure. `retryable` is the launcher's decision (descriptor-free, not aborted). */
	| Readonly<{ kind: "failed"; result: R; retryable: boolean }>
	/** Cancel semantics. `reason` is present only when a launch effect itself failed — a crash in the
	 *  launch path must stay distinguishable from a user cancellation. */
	| Readonly<{ kind: "aborted"; reason?: string }>;

export type EntryPhase = "queued" | "running" | "settled";

export type PoolEntry<A, R> = Readonly<{
	readonly id: string;
	readonly callId: string;
	readonly payload: A;
	/** Whether a failed attempt may be re-enqueued (false for Loom emission tasks: single-use staging). */
	readonly retryable: boolean;
	readonly maxAttempts: number;
	readonly phase: EntryPhase;
	/** Launches performed so far. Bounded by maxAttempts. */
	readonly attempts: number;
	/** Present only when phase === "settled". */
	readonly outcome: PoolOutcome<R> | null;
}>;

export type PoolState<A, R> = Readonly<{
	readonly cap: number;
	readonly entries: readonly PoolEntry<A, R>[];
}>;

export type PoolSnapshot = Readonly<{
	readonly cap: number;
	readonly queued: number;
	readonly running: number;
	readonly settled: number;
}>;

export type EntryRefusal =
	| Readonly<{ kind: "unknown-entry"; id: string }>
	| Readonly<{ kind: "not-queued"; id: string; phase: EntryPhase }>
	| Readonly<{ kind: "not-running"; id: string; phase: EntryPhase }>
	| Readonly<{ kind: "duplicate-id"; id: string }>;

/** The one construction-boundary check for a pool's cap: a cap below 1 wedges the queue forever
 *  (planLaunches never reserves) and a non-finite cap silently disables the running ≤ cap invariant. */
function assertCap(cap: number): void {
	if (!Number.isSafeInteger(cap) || cap < 1) {
		throw new TypeError(`pool cap must be a safe integer >= 1, got ${cap}`);
	}
}

export const emptyPool = <A, R>(cap: number): PoolState<A, R> => {
	assertCap(cap);
	return Object.freeze({ cap, entries: Object.freeze([]) });
};

/** Append one task at the tail of the queue. Identity is the caller's id; duplicates are refused. */
export function enqueue<A, R>(
	pool: PoolState<A, R>,
	item: Readonly<{ id: string; callId: string; payload: A; retryable: boolean; maxAttempts: number }>,
): Result<PoolState<A, R>, EntryRefusal> {
	if (pool.entries.some((entry) => entry.id === item.id)) return err({ kind: "duplicate-id", id: item.id });
	const entry: PoolEntry<A, R> = Object.freeze({
		...item,
		phase: "queued",
		attempts: 0,
		outcome: null,
	});
	return ok(Object.freeze({ ...pool, entries: Object.freeze([...pool.entries, entry]) }));
}

/**
 * Reserve slots for the next queued entries, FIFO, never exceeding the cap. Returned entries are already
 * `running` in the returned pool, so the shell may await their launches without a reentrant pump
 * exceeding the cap.
 */
export function planLaunches<A, R>(
	pool: PoolState<A, R>,
): Readonly<{ pool: PoolState<A, R>; launching: readonly PoolEntry<A, R>[] }> {
	const running = pool.entries.filter((entry) => entry.phase === "running").length;
	let capacity = Math.max(0, pool.cap - running);
	const launching: PoolEntry<A, R>[] = [];
	const entries = pool.entries.map((entry): PoolEntry<A, R> => {
		if (entry.phase !== "queued" || capacity === 0) return entry;
		capacity -= 1;
		const reserved: PoolEntry<A, R> = Object.freeze({ ...entry, phase: "running", attempts: entry.attempts + 1 });
		launching.push(reserved);
		return reserved;
	});
	return Object.freeze({
		pool: Object.freeze({ ...pool, entries: Object.freeze(entries) }),
		launching: Object.freeze(launching),
	});
}

/**
 * Settle one running entry. A process-level failure with retry budget left moves to the tail of the queue
 * (fair FIFO across calls); everything else is terminal. Settling anything not running is a typed refusal,
 * so no path can double-settle an entry.
 */
export function settleEntry<A, R>(
	pool: PoolState<A, R>,
	id: string,
	outcome: PoolOutcome<R>,
): Result<PoolState<A, R>, EntryRefusal> {
	const index = pool.entries.findIndex((entry) => entry.id === id);
	if (index === -1) return err({ kind: "unknown-entry", id });
	const entry = pool.entries[index];
	if (entry.phase !== "running") return err({ kind: "not-running", id, phase: entry.phase });

	// The entry's own `retryable` gates the retry: Loom emission tasks are single-use.
	const retry =
		entry.retryable && outcome.kind === "failed" && outcome.retryable && entry.attempts < entry.maxAttempts;
	// Ledger order is scheduling order, not the call's result order: the shell maps drained entries by
	// payload.index, so results[i] is task i regardless of ledger position (I13). A terminal settlement
	// keeps its position; only a retry requeues at the tail, for FIFO fairness across calls.
	const entries = retry
		? [
			...pool.entries.filter((_candidate, position) => position !== index),
			Object.freeze({ ...entry, phase: "queued" as const, outcome: null }),
		]
		: pool.entries.map((candidate, position) =>
			position === index ? Object.freeze({ ...candidate, phase: "settled" as const, outcome }) : candidate,
		);
	return ok(Object.freeze({ ...pool, entries: Object.freeze(entries) }));
}

/**
 * Abort one call: its queued entries become terminal as aborted; its running entries are left for the
 * shell to abort (their launch promises settle as "aborted"). Cancel semantics, not failure: no retry.
 */
/** The one cancel-semantics settlement: terminal, no retry, no result payload. */
const settleAborted = <A, R>(entry: PoolEntry<A, R>): PoolEntry<A, R> =>
	Object.freeze({ ...entry, phase: "settled" as const, outcome: Object.freeze({ kind: "aborted" as const }) });

export function abortQueued<A, R>(pool: PoolState<A, R>, callId: string): PoolState<A, R> {
	return Object.freeze({
		...pool,
		entries: Object.freeze(
			pool.entries.map((entry): PoolEntry<A, R> =>
				entry.callId === callId && entry.phase === "queued" ? settleAborted(entry) : entry,
			),
		),
	});
}

/** Cancel one queued entry (the user cancelled a not-yet-launched task). */
export function cancelQueued<A, R>(pool: PoolState<A, R>, id: string): Result<PoolState<A, R>, EntryRefusal> {
	const index = pool.entries.findIndex((entry) => entry.id === id);
	if (index === -1) return err({ kind: "unknown-entry", id });
	const entry = pool.entries[index];
	if (entry.phase !== "queued") return err({ kind: "not-queued", id, phase: entry.phase });
	return ok(Object.freeze({
		...pool,
		entries: Object.freeze(
			pool.entries.map((candidate, position) => (position === index ? settleAborted(candidate) : candidate)),
		),
	}));
}

export const callEntries = <A, R>(pool: PoolState<A, R>, callId: string): readonly PoolEntry<A, R>[] =>
	pool.entries.filter((entry) => entry.callId === callId);

export const drainedCall = <A, R>(pool: PoolState<A, R>, callId: string): boolean =>
	callEntries(pool, callId).every((entry) => entry.phase === "settled");

/** Drop a drained call's entries; the shell has reported them and releases their launchers. */
export function releaseCall<A, R>(pool: PoolState<A, R>, callId: string): PoolState<A, R> {
	return Object.freeze({ ...pool, entries: Object.freeze(pool.entries.filter((entry) => entry.callId !== callId)) });
}

export const snapshotOf = <A, R>(pool: PoolState<A, R>): PoolSnapshot =>
	Object.freeze({
		cap: pool.cap,
		queued: pool.entries.filter((entry) => entry.phase === "queued").length,
		running: pool.entries.filter((entry) => entry.phase === "running").length,
		settled: pool.entries.filter((entry) => entry.phase === "settled").length,
	});

// ---------------------------------------------------------------------------------------------
// Options and governance (pure)
// ---------------------------------------------------------------------------------------------

export type PoolOptions = Readonly<{ background: boolean; maxAttempts: number }>;

export type PoolOptionError = Readonly<{ kind: "invalid"; reason: string }>;

/** Normalise the tool parameter: absent/false ⇒ not pooled; true ⇒ pooled with defaults. */
export function normalizePoolOption(
	raw: boolean | Readonly<{ background?: boolean; maxAttempts?: number }> | undefined,
): Result<PoolOptions | null, PoolOptionError> {
	if (raw === undefined || raw === false) return ok(null);
	if (raw === true) return ok({ background: false, maxAttempts: 1 });
	if (typeof raw !== "object" || raw === null) {
		return err({ kind: "invalid", reason: "pool must be a boolean or an object" });
	}
	if (raw.background !== undefined && typeof raw.background !== "boolean") {
		return err({ kind: "invalid", reason: "pool.background must be a boolean" });
	}
	const maxAttempts = raw.maxAttempts ?? 1;
	if (typeof maxAttempts !== "number" || !Number.isSafeInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 3) {
		return err({ kind: "invalid", reason: "pool.maxAttempts must be an integer from 1 to 3" });
	}
	return ok({ background: raw.background ?? false, maxAttempts });
}

/**
 * Fail-closed governance heuristic (stage A): task text carrying Loom's emission descriptor, a `LOOM_`
 * token or a `Task ID:` binding is Loom-governed. Loom settles graph-governed batches from the tool result
 * (DESIGN-pool.md §3.2), so background must refuse them; blocking is always allowed. Stage B replaces this
 * with a capability probe answered by Loom.
 */
export function looksLoomGoverned(taskTexts: readonly string[]): boolean {
	return taskTexts.some(
		(text) =>
			text.includes("LOOM_EMISSION_DESCRIPTOR:") ||
			/\bLOOM_[A-Z][A-Z0-9_]*\b/u.test(text) ||
			/(^|\n)Task ID: /u.test(text),
	);
}

/** `PI_SUBAGENT_POOL_CONCURRENCY`: values above MAX_POOL_TASKS clamp to it; non-positive or malformed
 *  values fall back to the default. The environment seam lives at the createDispatcher call site. */
export function poolConcurrencyFromEnv(raw: string | undefined): number {
	if (raw === undefined || !/^\d+$/u.test(raw)) return DEFAULT_POOL_CONCURRENCY;
	const parsed = Number(raw);
	if (!Number.isSafeInteger(parsed) || parsed < 1) return DEFAULT_POOL_CONCURRENCY;
	return Math.min(parsed, MAX_POOL_TASKS);
}

/** The pool's retry policy in one pure home: the shell classifies the attempt's shape (aborted /
 *  process-level failure / semantic completion — `resultFailed` stays the shell's single predicate),
 *  the entry and its launch signal gate the retry. A task whose signal is already aborted never
 *  retries: a cancel/shutdown is not a failure, and a fresh attempt would escape its controller. */
export type AttemptResult = Readonly<{ exitCode: number; stopReason?: string }>;

export function classifyPoolAttempt<R extends AttemptResult, A>(
	entry: Pick<PoolEntry<A, R>, "retryable" | "attempts" | "maxAttempts">,
	result: R,
	signalAborted: boolean,
	isFailure: (result: R) => boolean,
): PoolOutcome<R> {
	if (signalAborted && result.stopReason === "aborted") return Object.freeze({ kind: "aborted" as const });
	if (!isFailure(result)) return Object.freeze({ kind: "completed" as const, result });
	const processLevel = result.exitCode !== 0 && result.stopReason !== "aborted";
	const retryable = entry.retryable && !signalAborted && processLevel && entry.attempts < entry.maxAttempts;
	return Object.freeze({ kind: "failed" as const, result, retryable });
}

// ---------------------------------------------------------------------------------------------
// Dispatcher shell
// ---------------------------------------------------------------------------------------------

export type DispatcherDeps<A, R> = Readonly<{
	cap: number;
	/** A task settled in a terminal state (retry scheduling already applied). */
	onSettle?: (entry: PoolEntry<A, R>, outcome: PoolOutcome<R>) => void;
	/** Every entry of a call reached a terminal state (or the call was aborted). */
	onCallDrained?: (callId: string, entries: readonly PoolEntry<A, R>[]) => void;
}>;

export type EnqueueRequest<A, R> = Readonly<{
	callId: string;
	items: readonly Readonly<{ id: string; payload: A; retryable: boolean }>[];
	maxAttempts: number;
	/** Per-entry launcher captured by the caller (routing snapshot, agents, slot identity). */
	launch: (entry: PoolEntry<A, R>, signal: AbortSignal) => Promise<PoolOutcome<R>>;
	signal?: AbortSignal;
	background: boolean;
}>;

export type Dispatcher<A, R> = Readonly<{
	/** Blocking: resolves at call drain. Background: resolves after the first launch wave. */
	enqueue: (request: EnqueueRequest<A, R>) => Promise<Readonly<{ entries: readonly PoolEntry<A, R>[]; background: boolean }>>;
	snapshot: () => PoolSnapshot;
	cancel: (id: string) => Result<boolean, EntryRefusal>;
	cancelCall: (callId: string) => void;
	cancelAll: () => void;
	entries: () => readonly PoolEntry<A, R>[];
}>;

/**
 * Create the process-wide dispatcher. The extension creates one per module instance; every pooled call
 * feeds the same queue, so the cap is global (a retry enqueued while other calls run starts on the next
 * freed slot).
 */
export function createDispatcher<A, R>(deps: DispatcherDeps<A, R>): Dispatcher<A, R> {
	assertCap(deps.cap);
	let pool = emptyPool<A, R>(deps.cap);
	const launchers = new Map<string, (entry: PoolEntry<A, R>, signal: AbortSignal) => Promise<PoolOutcome<R>>>();
	const controllers = new Map<string, AbortController>();
	const waiters = new Map<string, (entries: readonly PoolEntry<A, R>[]) => void>();
	const finalized = new Set<string>();
	let pumping = false;

	/** A diagnostic callback must never break settlement: a throw after `finalized` would leave the
	 *  call unreleased and its waiter unresolved, so every dep notification is isolated here. */
	const safeNotify = (notify: () => void): void => {
		try {
			notify();
		} catch {
			// The notification is best-effort by contract; settlement proceeds.
		}
	};

	function finalize(callId: string): void {
		if (finalized.has(callId) || !drainedCall(pool, callId)) return;
		finalized.add(callId);
		const entries = callEntries(pool, callId);
		const waiter = waiters.get(callId);
		waiters.delete(callId);
		// Release before notifying: a throwing dep callback must not strand the call's launchers,
		// controllers or waiter. The waiter resolves first, so the caller never waits on a diagnostic.
		pool = releaseCall(pool, callId);
		for (const entry of entries) {
			launchers.delete(entry.id);
			controllers.delete(entry.id);
		}
		waiter?.(entries);
		safeNotify(() => deps.onCallDrained?.(callId, entries));
	}

	/** Drop a call's queued work and abort its running tasks; their launch promises settle as aborted. */
	function abortCall(callId: string): void {
		pool = abortQueued(pool, callId);
		for (const entry of callEntries(pool, callId)) {
			if (entry.phase === "running") controllers.get(entry.id)?.abort();
		}
		finalize(callId);
		pump();
	}

	function pump(): void {
		if (pumping) return;
		pumping = true;
		try {
			for (;;) {
				const planned = planLaunches(pool);
				pool = planned.pool;
				if (planned.launching.length === 0) return;
				for (const entry of planned.launching) start(entry);
			}
		} finally {
			pumping = false;
		}
	}

	function start(entry: PoolEntry<A, R>): void {
		const controller = new AbortController();
		controllers.set(entry.id, controller);
		const launch = launchers.get(entry.id);
		const run = launch === undefined
			? Promise.resolve<PoolOutcome<R>>(Object.freeze({ kind: "aborted" as const }))
			: launch(entry, controller.signal);
		void run
			.then((outcome) => finish(entry.id, outcome))
			// The launcher contract is total; a violation settles as aborted rather than vanishing —
			// with the cause carried, so a launch crash stays distinguishable from a user cancellation.
			.catch((cause: unknown) =>
				finish(entry.id, Object.freeze({
					kind: "aborted" as const,
					reason: cause instanceof Error ? cause.message : String(cause),
				})));
	}

	function finish(id: string, outcome: PoolOutcome<R>): void {
		const entry = pool.entries.find((candidate) => candidate.id === id);
		if (entry === undefined) return;
		const settled = settleEntry(pool, id, outcome);
		if (!settled.ok) return;
		pool = settled.value;
		controllers.delete(id);
		const after = pool.entries.find((candidate) => candidate.id === id);
		if (after !== undefined && after.phase === "settled") safeNotify(() => deps.onSettle?.(after, outcome));
		finalize(entry.callId);
		pump();
	}

	return Object.freeze({
		enqueue: (request) => {
			finalized.delete(request.callId);
			for (const item of request.items) {
				const added = enqueue(pool, {
					id: item.id,
					callId: request.callId,
					payload: item.payload,
					retryable: item.retryable,
					maxAttempts: request.maxAttempts,
				});
				// The caller's ids are `${toolCallId}#${index}` and cannot collide; a refusal here is a
				// programming error and must be loud — a silently dropped item misaligns the batch.
				if (!added.ok) throw new Error(`pool enqueue refused ${item.id}: ${added.error.kind}`);
				pool = added.value;
				launchers.set(item.id, request.launch);
			}
			const done = new Promise<readonly PoolEntry<A, R>[]>((resolve) => {
				if (drainedCall(pool, request.callId)) resolve(callEntries(pool, request.callId));
				else waiters.set(request.callId, resolve);
			});
			if (request.signal !== undefined) {
				if (request.signal.aborted) abortCall(request.callId);
				else request.signal.addEventListener("abort", () => abortCall(request.callId), { once: true });
			}
			pump();
			return request.background
				? Promise.resolve({ entries: callEntries(pool, request.callId), background: true })
				: done.then((entries) => ({ entries, background: false }));
		},
		snapshot: () => snapshotOf(pool),
		cancel: (id) => {
			const entry = pool.entries.find((candidate) => candidate.id === id);
			if (entry === undefined) return err({ kind: "unknown-entry", id });
			if (entry.phase === "queued") {
				const cancelled = cancelQueued(pool, id);
				if (!cancelled.ok) return cancelled;
				pool = cancelled.value;
				finalize(entry.callId);
				pump();
				return ok(true);
			}
			if (entry.phase === "running") {
				controllers.get(id)?.abort();
				return ok(true);
			}
			return ok(false);
		},
		cancelCall: abortCall,
		cancelAll: () => {
			for (const controller of controllers.values()) controller.abort();
			for (const callId of new Set(pool.entries.map((entry) => entry.callId))) {
				pool = abortQueued(pool, callId);
			}
			pump();
			for (const callId of new Set(pool.entries.map((entry) => entry.callId))) finalize(callId);
		},
		entries: () => pool.entries,
	});
}
