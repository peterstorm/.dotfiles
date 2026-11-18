/**
 * Pool tests. `bun test pi/extensions/subagent/pool.test.ts` — the module under test has no pi imports, so
 * these run without the extension host.
 *
 * Pure tests pin the ledger invariants: the cap is never exceeded even with reentrant pumps, a launch
 * reserves its slot before it is awaited, retries are bounded and re-queued FIFO, and no entry settles twice.
 * Dispatcher tests pin the shell contract: blocking resolves at drain, background after the first wave,
 * cancellation drops queued work without retrying, and a freed slot refills mid-call.
 */
import { describe, expect, test } from "bun:test";
import {
	MAX_POOL_TASKS,
	type PoolEntry,
	type PoolOutcome,
	type PoolState,
	abortQueued,
	callEntries,
	cancelQueued,
	classifyPoolAttempt,
	createDispatcher,
	drainedCall,
	emptyPool,
	enqueue,
	looksLoomGoverned,
	normalizePoolOption,
	planLaunches,
	poolConcurrencyFromEnv,
	releaseCall,
	settleEntry,
	snapshotOf,
} from "./pool.js";

const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

function must<T, E>(result: { ok: true; value: T } | { ok: false; error: E }): T {
	if (!result.ok) throw new Error(`expected ok, got ${JSON.stringify(result.error)}`);
	return result.value;
}

const add = (
	pool: PoolState<string, string>,
	id: string,
	callId = "call-1",
	extra: { retryable?: boolean; maxAttempts?: number } = {},
) =>
	must(
		enqueue(pool, {
			id,
			callId,
			payload: `${callId}:${id}`,
			retryable: extra.retryable ?? false,
			maxAttempts: extra.maxAttempts ?? 1,
		}),
	);

const settle = (
	pool: PoolState<string, string>,
	id: string,
	outcome: PoolOutcome<string> = { kind: "completed", result: "done" },
) => must(settleEntry(pool, id, outcome));

const phases = (pool: PoolState<string, string>) => pool.entries.map((entry) => `${entry.id}:${entry.phase}`);

describe("pure ledger", () => {
	test("planLaunches fills FIFO up to the cap and reserves each slot", () => {
		let pool = emptyPool<string, string>(2);
		for (const id of ["a", "b", "c"]) pool = add(pool, id);

		const first = planLaunches(pool);
		expect(first.launching.map((entry) => entry.id)).toEqual(["a", "b"]);
		expect(phases(first.pool)).toEqual(["a:running", "b:running", "c:queued"]);
		expect(snapshotOf(first.pool)).toEqual({ cap: 2, queued: 1, running: 2, settled: 0 });

		// A reentrant pump on the reserved state launches nothing: the cap is already committed.
		expect(planLaunches(first.pool).launching).toEqual([]);

		const afterSettle = settle(first.pool, "a");
		expect(planLaunches(afterSettle).launching.map((entry) => entry.id)).toEqual(["c"]);
	});

	test("retry moves a failed entry to the tail and is bounded by maxAttempts", () => {
		let pool = emptyPool<string, string>(1);
		pool = add(pool, "a", "call-1", { retryable: true, maxAttempts: 2 });
		pool = add(pool, "b");

		const first = planLaunches(pool);
		const failed: PoolOutcome<string> = { kind: "failed", result: "boom", retryable: true };
		pool = settle(first.pool, "a", failed);

		// Retry is re-queued behind b: a freed slot serves the oldest waiter, not the retried task.
		expect(phases(pool)).toEqual(["b:queued", "a:queued"]);
		const second = planLaunches(pool);
		expect(second.launching.map((entry) => entry.id)).toEqual(["b"]);
		const third = planLaunches(settle(second.pool, "b"));

		// Second and final attempt fails: attempts == maxAttempts, so it settles instead of retrying.
		pool = settle(third.pool, "a", failed);
		expect(phases(pool)).toEqual(["b:settled", "a:settled"]);
		expect(pool.entries.map((entry) => entry.id)).toEqual(["b", "a"]);
		expect(pool.entries.find((entry) => entry.id === "a")?.attempts).toBe(2);
	});

	test("a non-retryable failure settles; a retryable flag on maxAttempts=1 settles", () => {
		let pool = emptyPool<string, string>(1);
		pool = add(pool, "a", "call-1", { retryable: false, maxAttempts: 3 });
		pool = settle(planLaunches(pool).pool, "a", { kind: "failed", result: "boom", retryable: true });
		expect(phases(pool)).toEqual(["a:settled"]);

		let single = emptyPool<string, string>(1);
		single = add(single, "b", "call-2", { retryable: true, maxAttempts: 1 });
		single = settle(planLaunches(single).pool, "b", { kind: "failed", result: "boom", retryable: true });
		expect(phases(single)).toEqual(["b:settled"]);
	});

	test("an entry settles exactly once; stale settles are typed refusals", () => {
		let pool = emptyPool<string, string>(1);
		pool = add(pool, "a");
		pool = settle(planLaunches(pool).pool, "a");

		const again = settleEntry(pool, "a", { kind: "completed", result: "again" });
		expect(again.ok).toBe(false);
		if (!again.ok) expect(again.error.kind).toBe("not-running");

		const unknown = settleEntry(pool, "zzz", { kind: "completed", result: "x" });
		expect(unknown.ok).toBe(false);
		if (!unknown.ok) expect(unknown.error.kind).toBe("unknown-entry");

		const duplicate = enqueue(pool, {
			id: "a",
			callId: "call-1",
			payload: "x",
			retryable: false,
			maxAttempts: 1,
		});
		expect(duplicate.ok).toBe(false);
	});

	test("abortQueued drops queued work but never touches running work", () => {
		let pool = emptyPool<string, string>(1);
		pool = add(pool, "a");
		pool = add(pool, "b");
		pool = planLaunches(pool).pool;

		pool = abortQueued(pool, "call-1");
		expect(phases(pool)).toEqual(["a:running", "b:settled"]);
		expect(pool.entries[1].outcome).toEqual({ kind: "aborted" });

		// Aborted entries are terminal: a cancel refuses them.
		expect(cancelQueued(pool, "b").ok).toBe(false);
	});

	test("cancelQueued only cancels queued entries", () => {
		let pool = emptyPool<string, string>(1);
		pool = add(pool, "a");
		pool = add(pool, "b");
		pool = planLaunches(pool).pool;

		expect(cancelQueued(pool, "a").ok).toBe(false);
		const cancelled = must(cancelQueued(pool, "b"));
		expect(phases(cancelled)).toEqual(["a:running", "b:settled"]);
	});

	test("a terminal settlement keeps its ledger position", () => {
		let pool = emptyPool<string, string>(2);
		pool = add(pool, "a", "call-1");
		pool = add(pool, "b", "call-1");
		pool = planLaunches(pool).pool;

		// b settles first; the ledger still reports a then b, which is the result order callers map
		// to their input slots. Only a retry moves an entry to the tail.
		pool = settle(pool, "b");
		expect(pool.entries.map((entry) => entry.id)).toEqual(["a", "b"]);
		expect(phases(pool)).toEqual(["a:running", "b:settled"]);
	});

	test("drainedCall and releaseCall keep calls isolated", () => {
		let pool = emptyPool<string, string>(2);
		pool = add(pool, "a", "call-1");
		pool = add(pool, "b", "call-2");
		pool = planLaunches(pool).pool;

		expect(drainedCall(pool, "call-1")).toBe(false);
		pool = settle(pool, "a");
		expect(drainedCall(pool, "call-1")).toBe(true);
		expect(drainedCall(pool, "call-2")).toBe(false);
		expect(callEntries(pool, "call-2").map((entry) => entry.id)).toEqual(["b"]);

		const released = releaseCall(pool, "call-1");
		expect(released.entries.map((entry) => entry.id)).toEqual(["b"]);
	});

	test("randomized transitions preserve the ledger invariants", () => {
		// Seeded LCG: a property over event sequences, no external dependency.
		let seed = 0x5eed_1234;
		const next = (bound: number): number => {
			seed = (seed * 1_664_525 + 1_013_904_223) >>> 0;
			return seed % bound;
		};

		for (let run = 0; run < 200; run += 1) {
			const cap = 1 + next(4);
			let pool = emptyPool<string, string>(cap);
			let counter = 0;

			for (let step = 0; step < 40; step += 1) {
				const action = next(4);
				const running = pool.entries.filter((entry) => entry.phase === "running");
				if (action === 0 && pool.entries.length < 12) {
					pool = add(pool, `t${counter++}`, `call-${next(3)}`, {
						retryable: next(2) === 0,
						maxAttempts: 1 + next(3),
					});
				} else if (action === 1) {
					const planned = planLaunches(pool);
					pool = planned.pool;
					expect(planned.launching.length).toBeLessThanOrEqual(cap);
				} else if (action === 2 && running.length > 0) {
					const target = running[next(running.length)];
					const outcome: PoolOutcome<string> =
						next(3) === 0
							? { kind: "failed", result: "boom", retryable: next(2) === 0 }
							: next(5) === 0
								? { kind: "aborted" }
								: { kind: "completed", result: "done" };
					pool = settle(pool, target.id, outcome);
				} else if (action === 3 && running.length > 0) {
					pool = abortQueued(pool, running[next(running.length)].callId);
				}

				const snapshot = snapshotOf(pool);
				expect(snapshot.running).toBeLessThanOrEqual(cap);
				expect(snapshot.running + snapshot.queued + snapshot.settled).toBe(pool.entries.length);
				for (const entry of pool.entries) {
					expect(entry.attempts).toBeLessThanOrEqual(entry.maxAttempts);
					// Exactly one terminal representation: settled ⇔ has an outcome.
					expect(entry.phase === "settled").toBe(entry.outcome !== null);
				}
			}
		}
	});
});

describe("options", () => {
	test("a cap below 1 or non-finite is refused at construction, not wedged silently", () => {
		for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY, 1.5]) {
			expect(() => emptyPool<string, string>(bad)).toThrow(TypeError);
			expect(() => createDispatcher<string, string>({ cap: bad })).toThrow(TypeError);
		}
		expect(() => emptyPool<string, string>(1)).not.toThrow();
	});

	test("normalizePoolOption parses the tool parameter", () => {
		expect(normalizePoolOption(undefined)).toEqual({ ok: true, value: null });
		expect(normalizePoolOption(false)).toEqual({ ok: true, value: null });
		expect(normalizePoolOption(true)).toEqual({ ok: true, value: { background: false, maxAttempts: 1 } });
		expect(normalizePoolOption({ background: true })).toEqual({
			ok: true,
			value: { background: true, maxAttempts: 1 },
		});
		expect(normalizePoolOption({ maxAttempts: 3 })).toEqual({
			ok: true,
			value: { background: false, maxAttempts: 3 },
		});
		for (const bad of [{ maxAttempts: 0 }, { maxAttempts: 4 }, { maxAttempts: 1.5 }, { background: "yes" }]) {
			expect(normalizePoolOption(bad as never).ok).toBe(false);
		}
	});

	test("looksLoomGoverned is fail-closed on Loom's binding surfaces", () => {
		expect(looksLoomGoverned(["implement the thing"])).toBe(false);
		expect(looksLoomGoverned(["LOOM_EMISSION_DESCRIPTOR: {...}"])).toBe(true);
		expect(looksLoomGoverned(["see LOOM_TASK_ID for details"])).toBe(true);
		expect(looksLoomGoverned(["binding\nTask ID: wave-1/impl-2\n"])).toBe(true);
		// Mid-line "Task ID:" is prose, not the binding header.
		expect(looksLoomGoverned(["the Task ID: is not a binding"])).toBe(false);
	});

	test("poolConcurrencyFromEnv clamps and defaults", () => {
		expect(poolConcurrencyFromEnv(undefined)).toBe(8);
		expect(poolConcurrencyFromEnv("4")).toBe(4);
		expect(poolConcurrencyFromEnv("0")).toBe(8);
		expect(poolConcurrencyFromEnv("-2")).toBe(8);
		expect(poolConcurrencyFromEnv("abc")).toBe(8);
		expect(poolConcurrencyFromEnv("999")).toBe(MAX_POOL_TASKS);
	});

	test("classifyPoolAttempt is the one home of the retry policy", () => {
		const entry = { retryable: true, attempts: 1, maxAttempts: 2 };
		const isFailure = (result: { exitCode: number; stopReason?: string }): boolean =>
			result.exitCode !== 0 || result.stopReason === "error" || result.stopReason === "aborted";

		// Semantic completion.
		expect(classifyPoolAttempt(entry, { exitCode: 0 }, false, isFailure)).toEqual({
			kind: "completed",
			result: { exitCode: 0 },
		});
		// Process-level failure within budget: retryable.
		expect(classifyPoolAttempt(entry, { exitCode: 7 }, false, isFailure)).toEqual({
			kind: "failed",
			result: { exitCode: 7 },
			retryable: true,
		});
		// Budget exhausted: settles failed, never retries.
		expect(classifyPoolAttempt({ ...entry, attempts: 2 }, { exitCode: 7 }, false, isFailure)).toEqual({
			kind: "failed",
			result: { exitCode: 7 },
			retryable: false,
		});
		// Entry-level gate: a single-use (descriptor-bearing) task never retries.
		expect(classifyPoolAttempt({ ...entry, retryable: false }, { exitCode: 7 }, false, isFailure)).toEqual({
			kind: "failed",
			result: { exitCode: 7 },
			retryable: false,
		});
		// A cancel that lands mid-failure never respawns the task on a fresh controller.
		expect(classifyPoolAttempt(entry, { exitCode: 7 }, true, isFailure)).toEqual({
			kind: "failed",
			result: { exitCode: 7 },
			retryable: false,
		});
		// The abort collapse: observed abort under an aborted signal is cancel semantics.
		expect(classifyPoolAttempt(entry, { exitCode: 1, stopReason: "aborted" }, true, isFailure)).toEqual({
			kind: "aborted",
		});
		// An aborted stop reason without an aborted signal is a failed attempt, not a cancel.
		expect(classifyPoolAttempt(entry, { exitCode: 1, stopReason: "aborted" }, false, isFailure)).toEqual({
			kind: "failed",
			result: { exitCode: 1, stopReason: "aborted" },
			retryable: false,
		});
	});
});

describe("dispatcher", () => {
	type Harness = Readonly<{
		dispatcher: ReturnType<typeof createDispatcher<string, string>>;
		launch: (entry: PoolEntry<string, string>, signal: AbortSignal) => Promise<PoolOutcome<string>>;
		started: string[];
		settle: (id: string, outcome: PoolOutcome<string>) => void;
		drained: string[];
	}>;

	function harness(cap: number): Harness {
		const started: string[] = [];
		const drained: string[] = [];
		const pending = new Map<string, (outcome: PoolOutcome<string>) => void>();
		const dispatcher = createDispatcher<string, string>({
			cap,
			onCallDrained: (callId) => drained.push(callId),
		});
		const launch = (entry: PoolEntry<string, string>, signal: AbortSignal): Promise<PoolOutcome<string>> => {
			started.push(entry.id);
			return new Promise<PoolOutcome<string>>((resolve) => {
				pending.set(entry.id, resolve);
				signal.addEventListener("abort", () => resolve({ kind: "aborted" }), { once: true });
			});
		};
		return {
			dispatcher,
			launch,
			started,
			drained,
			settle: (id, outcome) => {
				const resolve = pending.get(id);
				if (resolve === undefined) throw new Error(`task ${id} not running`);
				resolve(outcome);
			},
		};
	}

	test("the cap is global across calls and a freed slot refills mid-call", async () => {
		const h = harness(2);
		const launching = h.dispatcher.enqueue({
			callId: "a",
			items: [
				{ id: "a0", payload: "p", retryable: false },
				{ id: "a1", payload: "p", retryable: false },
				{ id: "a2", payload: "p", retryable: false },
			],
			maxAttempts: 1,
			launch: h.launch,
			background: false,
		});
		const waiting = h.dispatcher.enqueue({
			callId: "b",
			items: [{ id: "b0", payload: "p", retryable: false }],
			maxAttempts: 1,
			launch: h.launch,
			background: false,
		});
		await flush();
		expect(h.started).toEqual(["a0", "a1"]);

		h.settle("a0", { kind: "completed", result: "done" });
		await flush();
		// The freed slot serves the queue, not a fresh batch barrier: a2 runs while a1 is still live.
		expect(h.started).toEqual(["a0", "a1", "a2"]);

		h.settle("a1", { kind: "completed", result: "done" });
		await flush();
		expect(h.started).toEqual(["a0", "a1", "a2", "b0"]);
		h.settle("a2", { kind: "completed", result: "done" });
		h.settle("b0", { kind: "completed", result: "done" });
		await flush();

		const first = await launching;
		const second = await waiting;
		expect(first.entries.map((entry) => entry.id)).toEqual(["a0", "a1", "a2"]);
		expect(second.entries.map((entry) => entry.id)).toEqual(["b0"]);
		expect(h.drained).toEqual(["a", "b"]);
	});

	test("blocking resolves at drain; background resolves after the first wave and reports at drain", async () => {
		const h = harness(1);
		const blocking = h.dispatcher.enqueue({
			callId: "blocking",
			items: [
				{ id: "b0", payload: "p", retryable: false },
				{ id: "b1", payload: "p", retryable: false },
			],
			maxAttempts: 1,
			launch: h.launch,
			background: false,
		});
		await flush();
		expect(h.started).toEqual(["b0"]);

		const background = await h.dispatcher.enqueue({
			callId: "background",
			items: [{ id: "g0", payload: "p", retryable: false }],
			maxAttempts: 1,
			launch: h.launch,
			background: true,
		});
		expect(background.background).toBe(true);
		expect(background.entries[0].phase).toBe("queued");
		expect(h.drained).toEqual([]);

		h.settle("b0", { kind: "completed", result: "done" });
		await flush();
		expect(h.started).toEqual(["b0", "b1"]);

		h.settle("b1", { kind: "completed", result: "done" });
		await flush();
		const finishedBlocking = await blocking;
		expect(finishedBlocking.entries.map((entry) => entry.phase)).toEqual(["settled", "settled"]);
		expect(h.started).toEqual(["b0", "b1", "g0"]);

		h.settle("g0", { kind: "completed", result: "done" });
		await flush();
		expect(h.drained).toEqual(["blocking", "background"]);
	});

	test("a process-level failure retries up to maxAttempts and reuses the same launcher", async () => {
		const h = harness(1);
		const attempts = new Map<string, number>();
		const pending: Array<() => void> = [];
		const launch = (entry: PoolEntry<string, string>): Promise<PoolOutcome<string>> => {
			attempts.set(entry.id, (attempts.get(entry.id) ?? 0) + 1);
			h.started.push(`${entry.id}#${attempts.get(entry.id)}`);
			return new Promise((resolve) => {
				pending.push(() => resolve({ kind: "failed", result: "boom", retryable: true }));
			});
		};

		const call = h.dispatcher.enqueue({
			callId: "retry",
			items: [{ id: "r0", payload: "p", retryable: true }],
			maxAttempts: 2,
			launch,
			background: false,
		});
		await flush();
		expect(h.started).toEqual(["r0#1"]);

		pending.shift()?.();
		await flush();
		expect(h.started).toEqual(["r0#1", "r0#2"]);

		pending.shift()?.();
		await flush();
		const result = await call;
		expect(result.entries).toHaveLength(1);
		expect(result.entries[0].attempts).toBe(2);
		expect(result.entries[0].outcome).toEqual({ kind: "failed", result: "boom", retryable: true });
		expect(h.drained).toEqual(["retry"]);
	});

	test("abort drops queued tasks, aborts running ones, and never retries", async () => {
		const h = harness(1);
		const controller = new AbortController();
		const call = h.dispatcher.enqueue({
			callId: "abort",
			items: [
				{ id: "a0", payload: "p", retryable: true },
				{ id: "a1", payload: "p", retryable: true },
			],
			maxAttempts: 3,
			launch: h.launch,
			signal: controller.signal,
			background: false,
		});
		await flush();
		expect(h.started).toEqual(["a0"]);

		controller.abort();
		const result = await call;
		expect(result.entries.map((entry) => entry.outcome)).toEqual([{ kind: "aborted" }, { kind: "aborted" }]);
		expect(h.started).toEqual(["a0"]);
		expect(h.drained).toEqual(["abort"]);
	});

	test("cancel drops a queued task and aborts a running one", async () => {
		const h = harness(1);
		const call = h.dispatcher.enqueue({
			callId: "cancel",
			items: [
				{ id: "c0", payload: "p", retryable: false },
				{ id: "c1", payload: "p", retryable: false },
			],
			maxAttempts: 1,
			launch: h.launch,
			background: false,
		});
		await flush();
		expect(h.dispatcher.cancel("c1")).toEqual({ ok: true, value: true });
		expect(h.dispatcher.cancel("missing").ok).toBe(false);
		expect(h.dispatcher.cancel("c0")).toEqual({ ok: true, value: true });
		const result = await call;
		expect(result.entries.map((entry) => entry.phase)).toEqual(["settled", "settled"]);
		expect(h.drained).toEqual(["cancel"]);
	});

	test("shutdown cancelAll settles queued work and aborts running work", async () => {
		const h = harness(1);
		void h.dispatcher.enqueue({
			callId: "shutdown",
			items: [
				{ id: "s0", payload: "p", retryable: true },
				{ id: "s1", payload: "p", retryable: true },
			],
			maxAttempts: 3,
			launch: h.launch,
			background: false,
		});
		await flush();
		expect(h.started).toEqual(["s0"]);

		h.dispatcher.cancelAll();
		await flush();
		expect(h.dispatcher.snapshot()).toEqual({ cap: 1, queued: 0, running: 0, settled: 0 });
		expect(h.drained).toEqual(["shutdown"]);
	});

	test("an already-aborted signal settles every entry with no launcher call", async () => {
		const h = harness(2);
		const controller = new AbortController();
		controller.abort();
		const call = h.dispatcher.enqueue({
			callId: "pre-aborted",
			items: [
				{ id: "p0", payload: "p", retryable: true },
				{ id: "p1", payload: "p", retryable: true },
			],
			maxAttempts: 2,
			launch: h.launch,
			signal: controller.signal,
			background: false,
		});
		const result = await call;
		expect(h.started).toEqual([]);
		expect(result.entries.map((entry) => entry.outcome)).toEqual([{ kind: "aborted" }, { kind: "aborted" }]);
		expect(h.drained).toEqual(["pre-aborted"]);
		expect(h.dispatcher.snapshot()).toEqual({ cap: 2, queued: 0, running: 0, settled: 0 });
	});

	test("a rejecting launcher settles the entry aborted with the cause carried", async () => {
		const h = harness(1);
		const call = h.dispatcher.enqueue({
			callId: "crash",
			items: [{ id: "x0", payload: "p", retryable: true }],
			maxAttempts: 2,
			launch: () => Promise.reject(new Error("routing snapshot exploded")),
			background: false,
		});
		const result = await call;
		expect(result.entries).toHaveLength(1);
		expect(result.entries[0].outcome).toEqual({
			kind: "aborted",
			reason: "routing snapshot exploded",
		});
		expect(h.dispatcher.snapshot()).toEqual({ cap: 1, queued: 0, running: 0, settled: 0 });
		expect(h.drained).toEqual(["crash"]);
	});

	test("a throwing dep callback cannot strand the call's waiter or release", async () => {
		const drained: string[] = [];
		const dispatcher = createDispatcher<string, string>({
			cap: 1,
			onCallDrained: (callId) => {
				drained.push(callId);
				throw new Error("notice flush exploded");
			},
		});
		const pending = new Map<string, (outcome: PoolOutcome<string>) => void>();
		const call = dispatcher.enqueue({
			callId: "notify",
			items: [{ id: "n0", payload: "p", retryable: false }],
			maxAttempts: 1,
			launch: (entry) =>
				new Promise<PoolOutcome<string>>((resolve) => {
					pending.set(entry.id, resolve);
				}),
			background: false,
		});
		await flush();
		pending.get("n0")?.({ kind: "completed", result: "done" });
		// The dep callback throws synchronously inside finalize; the blocking waiter must still resolve.
		const result = await call;
		expect(result.entries[0].outcome).toEqual({ kind: "completed", result: "done" });
		expect(drained).toEqual(["notify"]);
		expect(dispatcher.snapshot()).toEqual({ cap: 1, queued: 0, running: 0, settled: 0 });
	});
});
