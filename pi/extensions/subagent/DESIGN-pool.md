# Design: Subagent Pool — process-wide slot dispatcher, background mode, process-level retries

Status: design, not yet implemented.
Scope: `pi/extensions/subagent` (stage A). One small, optional Loom-side addition for stage B (§4.6).
Verified against: subagent extension (dotfiles), Loom @ `deb8c369` (main; #219/#220/#221/#222/#223 merged,
#224/#225 open PRs; #226/#227 open retro issues reviewed §3.7/§3.8).

---

## 1. Problem

The `subagent` tool caps one call at 8 tasks (`MAX_PARALLEL_TASKS`, `index.ts:56`) and runs them
8-wide (`MAX_CONCURRENCY`, `index.ts:62`). Consequences:

- 20 dispatches need 3 calls; each call **blocks until all its tasks settle** (`mapWithConcurrencyLimit`,
  `index.ts`). A batch is a barrier: when 7 tasks finish and one runs long, 7 engine slots idle until the
  straggler completes.
- Retries are only dispatchable **after** the barrier: tool result → parent turn continues → status re-read
  → next spawn call. A retry dispatch that becomes owed mid-batch waits for the whole batch.
- Loom runs hit this hardest: issue #213 records a Wave with ~25 implementation dispatches and a review
  restart reissuing 35 requests (multiple barrier-synchronized batches). #222 and #225 shrink the *volume*
  engine-side (restart reissues only exhausted slots; a fresh gate carries unchanged Tasks' accepted
  reviews) — the pool fixes the *shape*: barrier-free, always-8-wide draining of whatever volume remains.

## 2. Goals

1. **G1 — Always-full slots.** A process-wide dispatcher keeps exactly `MAX_CONCURRENCY` (8) children
   running across *all* pool calls; any task finishing anywhere frees its slot for the next queued task.
2. **G2 — Background mode.** A pool call may return immediately; completions are injected into the session
   as messages (monitor-extension pattern), so the operator can read status and dispatch retries while the
   wave runs. *For Loom-orchestrated batches this needs the stage-B Loom-side change (§4.6) — the tool
   result is Loom's settlement vehicle (§3.2).*
3. **G3 — Process-level retries.** Optional automatic re-dispatch of tasks that failed at the *process*
   level (non-zero exit / `stopReason: error|aborted`, i.e. `resultFailed`). Never semantic retries —
   those stay engine-owned (§6.1).
4. **G4 — Loom compatibility without engine changes (stage A).** All launches happen through the existing
   `runSingleAgent` path (routing, brief expansion, admission leftovers, emission RPC, write grants
   unchanged).

Non-goals: raising engine concurrency (8 matches the engines: GLM v16 serves 8 slots; ds4-native runs 4
Lanes and queues the rest), Loom-side reservation re-stamping as a v1 requirement, cross-process pools.

## 3. Current mechanics this design must respect (verified)

### 3.1 Loom intercepts every `subagent` call before it executes

`isPiSpawnTool` = `subagent` | `loom_interactive_subagent` (`loom/pi/extension.ts:149`). On each call,
`prepareSpawnBatch` (`loom/pi/spawn-preparation.ts:68`) runs the ordered pipeline:

1. **Implementation-brief expansion** — a task of `LOOM_IMPLEMENTATION_BRIEF: <Task>` is replaced with the
   engine-rendered brief before any gate reads it (`implementation-brief-expansion.ts`). By the time our
   `execute()` runs, task text is already final: the pool must treat task text as **immutable at enqueue**.
2. **Spawn admission** — gates (template substitution, Task binding, attempt authority, write grant) judge
   the expanded batch. Admission is shape-agnostic: `spawnBatchEntries` iterates a `tasks` array of any
   length; there is **no Loom-side 8 cap**. Ours is the only cap.
3. **Launch staging** — one emission expectation per *emission-enabled* item is staged in the bridge,
   keyed `(sessionId, toolCallId, slot)` (`emission-launch-bridge.ts:118`). At child launch, the subagent
   extension emits `loom:subagent-launch:v2` resolve; the bridge answers exactly once from the staged
   entry, checking `sessionId/agent/task/cwd/effectiveModel` **byte-exact**
   (`emission-launch-bridge.ts:243`). Non-producer items are not staged (§3.3).

Everything a batch claims — roster identities, task-graph pointer lease, request correlators, review/
spec-check authorities, **write grants**, emission launches, task-execution registration — is taken **at
admission, before Pi dispatches the batch** (`loom/pi/spawn-lifecycle.ts` header): grants are injected into
the child prompts there, so a queued task's frozen text already carries its grant.

### 3.2 Loom settles from the tool result — the primary background constraint

`dispatchPiSubagentStop` runs on the tool's result event (`loom/pi/subagent-stop.ts:1071`). It then:

- `parsePiSubagentResults` (`subagent-result-batch.ts:53`) accepts any safe-integer `exitCode` — including
  the pool's `-1` running placeholder;
- `finalizeReservedImplementations(reservation, entries)` settles every graph-governed reserved result;
- `reconcileMissingReservedResults` terminalizes reservation slots absent from the result;
- then settles reviews/spec-checks and releases the reservation's claims.

**Consequence: a background tool result would prematurely settle a Loom wave's reservations (as failed)
while the children are still running.** `exitCode: -1` is a valid parse and `piSubagentResultFailed` reads
it as failed. This applies to *implementation* dispatches, which are non-producers (§3.3) — the emission
descriptor is not what blocks them here. Therefore, in stage A, **background mode is refused for
Loom-governed batches** (detection §4.5); stage B (§4.6) makes Loom settlement event-driven so background
works for it, which is what finally delivers mid-wave retries for Loom.

### 3.3 Producers vs implementations

`producerKindsOfAgent` (`engine/src/core/agent-catalog-projections.ts:93-115`) yields kinds only for
reviewers (`reviewer-payload`), refuters (`refutation-verdict`) and judges (`judge-verdict`). Implementation
agents answer `[]` — **non-producers**. So implementation briefs carry no `LOOM_EMISSION_DESCRIPTOR:` line;
only review/judge spawns do.

### 3.4 Staged emission expectations die with the tool call

`dispatchPiSubagentStop` calls `emissionLaunchBridge.removeToolCall(sessionId, toolCallId)` when the tool
result is emitted (`loom/pi/subagent-stop.ts:1071`; wipe at `emission-launch-bridge.ts:540`). A launch
**after** the tool result therefore resolves against nothing and stays `not-admitted`:
plain (non-descriptor) tasks spawn normally in JSON mode; descriptor tasks are hard-refused by
`runSingleAgent` ("Loom emission task was not admitted for emission RPC"). Rule: a descriptor-bearing task
is never launched post-return and never auto-retried.

### 3.5 Emission launches bind model + readiness at launch

An admission reply for an emission-enabled item requires an exact routed model (`effectiveModelForLaunch`)
and, once admitted, a directive with `verifyReadiness`. Routes are resolved once per call via
`buildRoutingSnapshot` (deliberately: one batch lands on one model). The pool freezes each queue entry's
resolved route at enqueue — consistent with that intent.

### 3.6 Reservations age only under observation

`RESERVATION_GRACE_MS = 10 min` (`core/validate-task-execution.ts:213`). A **running** child is shielded by
roster activity regardless of age; a **queued** task is not yet registered, so its pre-registration window
stretches with dwell. Crucially, reclaim fires only in an **admission's pre-roster observation** — and in a
**blocking** pool call no admission runs mid-call, so queued tasks' reservations cannot be reclaimed
during the call regardless of dwell. In **background** mode the parent does run later admissions (retry
dispatches), which *can* reclaim aged reservations of still-queued tasks; status then re-offers them and a
re-dispatch could double-run a queued task. Stage B (§4.6) fixes this by excluding pool-in-flight tasks from
reclaim; stage A documents it (§6.2).

### 3.7 Quiescence protocol (now including `amend-spec`)

Every graph-rewriting helper — `reopen-task`, `rescope-task`, `amend-spec-trace`, `add-dependency`,
`adopt-*`, and (merged #220) `amend-spec` — refuses while **any subagent is roster-active for the
TaskGraph** (`handlers/helpers/subagent-quiescence.ts`; probe `anyActiveSubagent` fail-closed,
`machine/ledger.ts:484`). Today the refusal window ≈ "while a `subagent` call is live". A background pool
keeps children running while the session is idle, so mid-wave recovery ops refuse more often. Not fatal
(fail-closed by design); the pool's duty is to make settling **observable** — not to discard owed work.

Roster liveness caveat (issue #227): `.active` roster entries are released as spawn claims at settlement or
by `shutdownPiSession` at parent shutdown — both normal pool paths release them. But roster liveness judges
only Claude Code ids (`roster-liveness.ts:36`), so a **hard-killed parent** strands Pi entries forever and
helpers refuse until hand-cleared. That is #227's class, not a pool defect; the pool minimizes exposure by
never SIGKILLing a child while the parent itself is alive and settling (cancel/shutdown drain first).

### 3.8 One run, one revision — widened by queues (issue #226)

A batch is admitted against the plugin checkout at revision A; children load the checkout's HEAD **at spawn
time**. If the checkout moves mid-batch, producer children (emission producers) die at their readiness
handshake and Loom reports only "absent or unusable" (the launcher's `errorMessage` is dropped in
`reconcileMissingReservedResults`, `pi/subagent-stop.ts:566-580`); implementation children load revision B
silently. **A pool widens the admission→spawn window** — queued tasks spawn minutes after admission — so
Loom's one-run-one-revision invariant must be enforced at each child spawn (#226 tier-1: re-validate the
admitted revision or pin the child to it). Until that lands: the extension must never drop the launcher's
`errorMessage` when reporting a failed launch, and operators should expect the queue to amplify mid-batch
revision skew. This is a Loom-side fix, not a pool change.

### 3.9 Retry semantics are engine-owned

Status derives each Task's owed dispatch from protected settlement history
(`core/task-implementation-dispatch.ts:36`): `initial-implementation` (attempt 1) or `retry-implementation`
(attempt 2, brief carries the retry appendix). The orchestrator never works from raw `pending`/
`retry_count` fields (`commands/loom.md:154`). Infrastructure-blocked attempts are re-dispatched under the
same kind without consuming an attempt. A pool that silently re-ran a failed attempt-2 child would be an
unauthorized attempt 3 — hence G3's split (§6.1).

## 4. Design

One new module, `pool.ts`; `index.ts` gains a `pool` parameter and routes pool calls through the dispatcher.
Same split as `monitor/` (`index.ts` boundary glue + `state.ts` pure core): **pure scheduler core** (queue +
running set + transitions, no I/O), **boundary glue** (spawn wiring, session messages, shutdown kills).

```
tool call (pool) ──enqueue──▶ dispatcher (module-global)
                                 │  FIFO queue
                                 │  running set ≤ MAX_CONCURRENCY
                                 │  per-task AbortController (pool-owned, not the call's signal)
                                 ▼
                          runSingleAgent(...)   ← unchanged: routing, admission leftovers,
                                                  brief text, emission RPC, write grants
                                 │ settle (SingleResult)
                                 ├─ blocking call: resolve awaiter when ITS tasks done
                                 ├─ background: coalesced pi.sendMessage(...) injection
                                 └─ maxAttempts>1 and process-level failure: re-enqueue (§4.4)
```

### 4.1 The dispatcher

Module-global, per pi process:

- `queue: PoolTask[]` — immutable entries: `{ id, agent, task, cwd, resolvedRoute, routingSnapshot, slot,
  attempts, enqueuedAt, controller }`. **Task text frozen at enqueue** (§3.1).
- `running: Map<id, RunningTask>` — capped at `MAX_CONCURRENCY` (env override
  `PI_SUBAGENT_POOL_CONCURRENCY`; default unchanged at 8).
- `enqueue()` → `pump()`: while `running.size < cap && queue.length > 0`, dequeue FIFO and launch;
  `pump()` again after every settle. This *is* "always fill the free slots" — event-driven refill, no
  polling timer needed (a settle is the only thing that frees a slot, and every settle pumps).
- Slot kinds: pool tasks reuse `SubagentLaunchSlot` (`{ kind: "parallel", index }`); in blocking mode the
  call is live, so bridge staging matches per slot.

### 4.2 Tool surface

```ts
subagent {
  ...existing params...,
  pool?: boolean | {
    background?: boolean;   // default false
    maxAttempts?: number;   // default 1; 1..3; process-level only
  },
}
```

- `pool` applies to **parallel `tasks` and single** calls. **Chain stays as-is** — steps are sequential by
  construction (`{previous}`); a pool adds nothing.
- `MAX_PARALLEL_TASKS` stays 8 for non-pool calls (backward compatible). Pool calls raise the per-call cap
  to **64** (Loom's `spawn-wave-implementation` says "spawn exactly `recovery.dispatches`"; a restart
  reissues 35 requests). Beyond 64: named refusal.
- Non-pool calls keep today's code path byte-for-byte — **I8**.

### 4.3 Blocking pool (stage A default; Loom's mode)

Call enqueues all N tasks, awaits **only the tasks it enqueued**, streams per-task updates exactly as
today's parallel mode (`exitCode: -1` placeholders → settle). All launches happen while the call is live:
§3.4 staging intact, §3.6 no reclaim mid-call, and the final tool result is fully settled — exactly what
Loom's settlement expects (§3.2). One call drains a whole 20-task wave; freed slots refill within the call.
Result shape unchanged (`SubagentDetails`, parallel sections, aggregate usage).

### 4.4 Background pool

- **Stage A (extension-only):** background is allowed only when the call is **not Loom-governed** (§4.5);
  a non-Loom background call has no graph reservation, so the snapshot tool result settles nothing Loom
  owns.
- Validates up front, refusing the **whole call** (fail-closed, Loom's all-or-nothing batch style):
  any task text carrying `LOOM_EMISSION_DESCRIPTOR:` or matching a Loom brief signature (§4.5) → refuse
  with a named reason.
- Returns immediately: content/details = snapshot ("N queued, M running, K done"); the turn ends; the
  session stays interactive.
- **Completions inject via `pi.sendMessage({ customType: "pool", ... }, { deliverAs: "steer",
  triggerTurn: true })`** — the monitor mechanism (`monitor/index.ts:161`). Coalesce settles within a ~2 s
  window (a 35-reviewer pool must not cause 35 turns); message carries agent, task id when extractable,
  ✓/✗, one-line output head, usage, running/queued counts, and in-flight task ids.
- Children are **not** tied to the tool call's `AbortSignal`; each task gets a pool-owned controller.

### 4.5 Governance detection (fail-closed)

Stage A needs to know whether the call is Loom-graph-governed. Two layers:

1. **Probe (clean path, tiny Loom-side addition):** emit `loom:pool-governance-probe:v1` on the extension
   bus; Loom's extension (which already owns spawn admission and knows the governing graph) answers
   `{ governed: boolean }` for `(sessionId, toolCallId)`. Absence of a responder → fall through.
2. **Heuristic fallback:** if any task text contains `LOOM_EMISSION_DESCRIPTOR:` or a `LOOM_` token or a
   `Task ID:` binding line → treat as Loom-governed (fail closed). Else background allowed.

The probe is ~30 lines in `loom/pi/extension.ts` (one `events.on` + handler). It keeps the Loom change
optional: without it, the heuristic refuses background conservatively.

### 4.6 Stage B — Loom-side deferred settlement (makes background work for Loom)

This is the change that delivers the original ask end-to-end: *engine requests a retry → a new subagent
starts immediately in a free slot, mid-wave.* The settlement vehicle changes from "one complete tool
result" to "a ledgered event stream". The safety argument is reconstructed below (§4.6.1–4.6.6), not
inherited: today's partial-state impossibility is replaced by illegal-states-unrepresentable plus
probe-gated ownership.

**4.6.1 The contract is a state machine, not a message.** New pure core
`loom/pi/pool-settlement-ledger.ts`, sibling of `subagent-settlement.ts`:

```ts
type SlotState =
  | { kind: "pending" }
  | { kind: "settled"; entry: ParsedResult }     // parsePiSubagentResults, one-element array
  | { kind: "terminalized"; reason: "missing" | "aborted" | "malformed" };

type Ledger =
  | { kind: "open"; slots: readonly SlotState[] }  // slot order = reservation item order
  | { kind: "released" };

applySettlement(ledger, event): Ledger | Refusal
//   Settle(slot, entry)  Pending → Settled; Settled/Terminalized → refused (idempotent)
//   Drain(aborted[])     Pending → Terminalized; Open → Released iff no Pending remains
//   Stale                Pending → Terminalized("missing"); Open → Released iff none Pending
//   any event on Released → refused (total over the ADT)
```

Structural consequences (types, not tests): a slot cannot settle twice; no settlement after release; the
`released` constructor is reachable only from an `open` ledger with no `pending` slot. Drain reconciliation
is a fold over `pending` — `reconcileMissingReservedResults`' behavior, reproduced.

**4.6.2 Background requires a live settlement handler.** Mirror the launch-bridge handshake:

```
probe  loom:pool-settlement:v1   →   Loom responds { kind: "available", version: 1 }
```

The responder **constructs and registers the ledger store** as it answers. The pool admits background for a
governed batch **iff the probe answers**; no answer or a version mismatch falls back to blocking
(fail-closed). "Background ran but nobody settles it" is unreachable by construction.

**4.6.3 The early tool result carries no results.** `details = { results: [], poolState: "running",
slots }` — no `-1` placeholders. A missing or wrong Loom branch then hits
`reconcileMissingReservedResults` with an empty array and terminalizes every slot **loudly**, instead of
silently settling placeholders as failures.

**4.6.4 Shutdown drain = today's abort result.** `session_shutdown` emits `pool-drained` with every
running/queued slot terminalized `aborted`, synchronously before exit — byte-equivalent to today's aborted
tool result. Only a hard crash (no handler) falls to the existing `RESERVATION_GRACE_MS` reclaim, which is
today's recovery path for a missing result. No new recovery mechanism.

**4.6.5 Batch-level settlement — scoping.** The genuine behavioral delta is batch context:
`resolveImplementationTaskId`'s sole-executing fallback (`pi/subagent-settlement.ts:293`) and
`attributeEvidence`'s sole-binding resolution (`engine/src/machine/evidence.ts:600`) see a different
roster/`executing_tasks` snapshot at per-event time. Mitigations:
- background v1 is admitted only when **every** reserved item's agent is in `IMPL_AGENTS` (implementation
  results bind `named` via reserved authority, off the sole fallback); review/judge (emission producers)
  and phase agents stay blocking;
- a **differential test** is the acceptance gate: the same N results through batch settlement vs per-entry
  settlement must produce byte-identical TaskGraph deltas.

**4.6.6 Wire shape and cross-checks.** `loom:pool-task-settled:v1` carries
`{ sessionId, toolCallId, slot, index, entry }`; `loom:pool-drained:v1` carries
`{ sessionId, toolCallId, abortedSlots }`. The pool announces its in-flight Task ids (from queue entries) in
the tool result details; admission's pre-roster observation excludes them from stale-reservation reclaim
(§3.6). Drain cross-checks the pool's report against the ledger; a mismatch is a processing error
(fail-closed, not silent). Duplicates are refused at the ledger; late events after release are refused.
Running pool children remain roster-active, so `anyActiveSubagent` (§3.7) needs no change — only the
operator experience changes (drain is now visible).

### 4.7 Process-level retries (`maxAttempts`)

- On settle with `resultFailed(result)` and `attempts < maxAttempts` and **no descriptor in task text**
  (single-use staging, §3.4) and **the pool did not abort it**: re-enqueue at the **tail** (FIFO fairness),
  `attempts + 1`, diagnostic appended to the task's result stderr ("retrying (attempt 2/2): <reason head>").
- Aborts are not retried (`controller.signal.aborted → no retry`) — a cancel/shutdown is not a failure.
- Semantic failures are not retried here: a child that ran its judgment and completed exits 0; the engine
  derives the authorized retry. Default `maxAttempts: 1` keeps Loom runs exactly as authorized.

### 4.8 `/pool` command

- `/pool` — table: id, agent, state (queued/running/✓/✗/retrying), attempt, elapsed, task head, Task id when
  extractable; totals (queued / running / cap).
- `/pool cancel <id|all>` — group **SIGTERM first**, wait up to 5 s (`GROUP_KILL_GRACE_MS`), then SIGKILL to
  the child's process group; task settles aborted, no retry. The grace window matters: the child's own
  shutdown handlers run under SIGTERM, and roster-claim release follows the parent's settlement, so a
  graceful cancel leaves no stranded state (#227 is only reachable when the *parent* dies hard). Monitor's
  hardened patterns: detached spawn + process-group kill (`process-group.ts`). The escalation fires
  **unconditionally** at the deadline — a group whose members are all gone makes the kill a no-op — and the
  same constant is imported by `rpc-launcher.ts`, so the cancel contract is one documented window for both
  launch paths (JSON and RPC/emission), not 5 s on one and 1 s on the other.
- Deliberately **no `drain`/`flush`**: queued pool tasks are owed dispatches; discarding them would drop
  Wave work. Quiescence comes from letting tasks settle — `/pool` and injected messages make it observable.

### 4.9 Lifetime: shutdown, abort, reload

- **Session shutdown** (`pi.on("session_shutdown")`, all reasons): SIGTERM, then SIGKILL after the 5 s grace,
  to each running child's process group. The handler is async and, when any entry is running, awaits a
  bounded `GROUP_KILL_GRACE_MS + 1 s` so the (unref'd) escalation timers fire before pi exits — early exit
  when the entries settle is deliberately avoided, because a settled direct child does not prove the group
  is empty. Pool children spawn **detached** (monitor pattern, `monitor/index.ts:328`) so the group kill is
  clean; orphan risk on SIGKILL of pi itself is parity with today's non-detached children.
- **User abort during a blocking pool call:** that call's tasks are killed, its queued tasks discarded,
  results returned as aborted (today's parallel abort semantics). Other calls unaffected.
- **`/reload` mid-pool:** shutdown kills children and orphans the queue — **documented stage-A boundary**.
  Future: monitor-style journal + adoption. Not v1.

## 5. Invariants (each testable)

1. **I1 — Cap.** `running.size ≤ MAX_CONCURRENCY` at every observable instant; `pump()` after every
   enqueue/settle; no other launch path for pool tasks.
2. **I2 — FIFO.** Launch order = enqueue order within a call; across calls, call order.
3. **I3 — Frozen identity.** Queue entry task text/agent/cwd/route immutable after enqueue (the byte-exact
   bridge mismatch check and Loom's grant-in-prompt depend on it).
4. **I4 — Call awaits its own.** A blocking call resolves when its own tasks settle; foreign tasks never
   appear in its results. FIFO slot sharing means foreign queued work *may delay its launches* by design
   (deterministic, not an error).
5. **I5 — Descriptor discipline.** A task whose text carries `LOOM_EMISSION_DESCRIPTOR:` is never launched
   post-tool-return and never auto-retried.
6. **I6 — Settlement discipline.** A background call is refused when governance detection (§4.5) says
   Loom-governed; a blocking call's tool result contains only settled results (no `-1` placeholders at
   return).
7. **I7 — Attempt bound.** A task launches at most `maxAttempts` times per call; default 1 = today.
8. **I8 — Abort correctness.** Blocking-call abort kills that call's tasks only; session shutdown kills
   every pool-owned child via process group + argv-marker identity; none survives shutdown.
9. **I9 — Default passthrough.** A call without `pool` executes the pre-pool path untouched
   (regression-guarded by the existing execution integration tests).
10. **I10 — Ledger totality.** Every reserved slot reaches exactly one terminal state; the ledger releases
    only when none is pending; every event is total over `Released` (refusal, never application).
    Duplicate settles and post-release events are refused.
11. **I11 — Probe-gated background.** A Loom-governed background call is impossible unless the settlement
    capability answered; absent/mismatched probe ⇒ blocking path.
12. **I12 — Empty early result.** A background tool result carries `results: []` + `poolState: "running"`;
    a missing branch terminalizes loudly at the existing reconciliation, never settles placeholders.
13. **I13 — Result order.** A blocked call's `results[i]` is the task enqueued at index `i`. The ledger is
    scheduling state, not the result order: a terminal settlement keeps its position, a retry requeues at
    the tail for FIFO fairness, and the shell maps drained entries by `payload.index` before building
    `results` — so the index correspondence holds unconditionally, not only when no retry fires. Loom maps
    a result index to a launch slot, so this is a correctness invariant, not formatting.

## 6. Loom interplay decisions

### 6.1 Who retries what

| Failure | Owner | Mechanism |
|---|---|---|
| Crash / non-zero exit / spawn error / killed | Pool (opt-in `maxAttempts`) | Tail re-enqueue, process-level, attempt-bounded |
| Semantic attempt failure (tests, drift, review) | Loom engine | `retry-implementation` dispatch, attempt-2 appendix, one authorized attempt 2 |
| Infrastructure-blocked attempt | Loom engine | Re-dispatch under same kind, attempt not consumed |
| Escalation (attempt 2 final) | Loom engine | `escalate-wave-implementation`; spawn gate refuses attempt 3 |

The pool's `maxAttempts` composes safely: a crashed attempt-2 child re-run by the pool is still attempt 2
(the engine counts settled attempts); semantic failures exit 0 and are never pool-retried; default
`maxAttempts: 1` keeps engine accounting untouched.

### 6.2 Reservations & dwell

**Blocking:** safe. Reclaim fires only in admission's pre-roster observation, and no admission runs
mid-call — a 20-deep queue's reservations stand regardless of dwell, and the parent is blocked so it cannot
re-dispatch. **Background (stage B):** the pool's own later spawn calls run admission and *can* reclaim
aged queued reservations; §4.6.6 (in-flight exclusion) closes this. Stage A excludes Loom from
background entirely, so the window never opens.

### 6.3 Quiescence & helper ops

Background mode trades helper-op availability for utilization: `reopen-task`, `rescope-task`,
`amend-spec-trace`, `add-dependency`, `adopt-*`, and `amend-spec` (merged) all refuse while any pool child
is roster-active. The pool's answer is observability, not work-discarding: wait for owed tasks to settle
(injected messages say when), then run the helper op, then re-read status.

### 6.4 What was checked for conflicts

- **Merged:** #219 (state-file guard by write targets; also hardens `core/subagent-authority.ts` child bash
  authority), #220 (`amend-spec`; quiescence now includes "spec amendment"), #221 (runtime seams),
  #222 (Wave Gate restart reissues only exhausted slots), #223 (phase gate places agents by identity).
- **Open issues:** #213 (Wave 2 rework root causes), #224/#225 (advisory dispositions; gate carries accepted
  reviews), **#226** (checkout move mid-batch kills children — the pool widens the admission→spawn window;
  §3.8), **#227** (dead Pi roster entries never reaped — normal pool paths release claims; only hard-killed
  parents strand; §3.7).
- **None touches `pi/extensions/subagent`, the launch-port v2 contract, or any cap.** #222/#225 reduce
  dispatch/review volume engine-side — complementary to the pool, which changes the shape of the remaining
  volume. #226's tier-1 revision pin is a Loom-side prerequisite for deep queues, not a stage-A blocker
  (the extension reports what it has; the launcher `errorMessage` must survive into results). No rebase or
  conflict expected.

## 7. Testing plan

- **Unit (`pool.test.ts`, 23 tests)** — scheduler core: cap with reentrant pumps, FIFO, reserve-before-launch,
  frozen entries, retry bound + entry-level `retryable` gate, terminal settlement keeps position while a
  retry moves to the tail (I13), descriptor refusal, governance-heuristic refusal, abort/cancel semantics,
  I4 semantics, and a seeded randomized invariant loop (cap / exactly-once / attempts bound); plus the cap
  construction guard (0/NaN refuse loudly), the `classifyPoolAttempt` retry-policy table (single-use, budget,
  aborted-signal gates), a pre-aborted signal settling every entry with no launch, a rejecting launcher
  settling aborted with the cause carried, and a throwing dep callback that cannot strand the waiter.
  Pure core ⇒ deterministic, no timers.
- **Integration (`pool.integration.test.ts`, 11 tests)** — drives the **registered tool** through a fake Pi
  host and a fake child (execPath substitution, the execution-suite pattern): blocking batch of 5 over cap 2
  keeps input order and never exceeds the cap (I1/I2/I13); invalid `maxAttempts`/chain/over-cap refuse before
  spawn; background + Loom signature refuses whole (I6); background non-Loom returns immediately, injects
  coalesced steer/triggerTurn messages, and reports the full snapshot; `maxAttempts: 2` re-enqueues a
  crashing child once (I7) and blocking results stay in input order when a task retries (I13); a
  descriptor-bearing task is single-use (I5); abort kills the whole process group, including a
  SIGTERM-ignoring grandchild (I8), and so does `session_shutdown` (the handler is captured and awaited);
  a pre-spawn throw resolves to a failed result instead of rejecting the call (P0-2 totality). The existing
  `execution.integration.test.ts` guards the no-pool path (I9).
- **Loom-shaped end-to-end** — 6-task wave, one child exits non-zero: assert no pool re-dispatch at default
  and that the tool result settles all six (Loom's path unchanged); with `maxAttempts: 2`, a SIGKILLed child
  is re-dispatched once.
- **Stage B proof obligations** (each a test, not prose):
  - *Ledger reducer, exhaustive transitions* — duplicate settle refused; late settle after drain/release
    refused; drain with pending slots terminalizes; second drain refused; unknown/wrong-toolCallId slot
    refused.
  - *Contract golden payloads* — the pool's event constructor output ≡ Loom's parser acceptance, pinned on
    both sides.
  - *Differential settlement* — batch vs per-entry settlement of the same impl results produce
    byte-identical TaskGraph deltas (acceptance gate for §4.6.5).
  - *Crash parity* — SIGKILL mid-pool ⇒ staleness reclaim yields the same graph as today's missing-result
    path.
  - *No-handler fallback* — probe unanswered ⇒ background refused, blocking used, nothing settled.
  - *Early-result branch* — `poolState: "running"` settles/reconciles nothing; removing the branch fails
    loud at reconciliation (I12).

## 8. Deployment

Source of truth: `~/.dotfiles/pi/extensions/subagent/`. **Deploys as a copied directory** (not a symlink,
unlike most extensions) to `~/.pi/agent/extensions/subagent`, kept byte-identical — edit here, copy there.
After merge: copy, then `/reload` in a session *without* an active pool (§4.9).

## 9. Corrections log (what changed across review passes)

- **Background mode for Loom — the premise was wrong.** Earlier passes treated the emission-descriptor
  staging wipe as the blocking constraint, implying implementation waves (non-producers) could run in
  background. The real constraint is §3.2: Loom settles graph-governed batches from the tool result, so a
  background snapshot settles them prematurely. Stage A therefore refuses background for any Loom-governed
  call; stage B (§4.6) defers settlement via events.
- **`/pool drain` dropped** (earlier pass): flushing queued work would discard owed `recovery.dispatches`.
  Replaced by `/pool cancel` + observable settling.
- **I4 was factually wrong** (earlier pass): foreign queue entries *do* delay a blocking call's launches via
  FIFO slot sharing; they only never appear in its results. Reworded.
- **Reservation reasoning** (earlier pass): reclaim is not triggered by dwell alone — only by an admission's
  pre-roster observation. Blocking mode is safe because *no admission runs mid-call*, which is stronger and
  more precise than "dwell is bounded".
- **PR states refreshed:** #219/#220 merged; #221–#223 merged; #224/#225 open. No conflicts with this
  design.
- **New retro issues reviewed** (#226 checkout-move mid-batch, #227 dead Pi rosters): neither changes stage A
  in shape. #226 is a real amplification risk for deep queues (wider admission→spawn window) but its fix is
  Loom-side one-run-one-revision enforcement (§3.8); the extension's obligation is only to never drop the
  launcher `errorMessage`. #227 is a Loom-side roster-liveness gap; normal pool paths release roster claims
  at settlement/shutdown, so the pool does not create stranded entries (§3.7). Both added to the hardening
  backlog and the conflict scan.
- **Stage B hardened** (final pass): the earlier "event-sourced settlement" sketch was made as safe as
  today's vehicle in code — ledger ADT (§4.6.1), probe-gated handler ownership (§4.6.2), result-free early
  tool result (§4.6.3), shutdown drain parity (§4.6.4), implementation-only scoping + differential test
  (§4.6.5), and explicit wire/cross-check rules (§4.6.6). The only deliberate trade left is mid-wave engine
  visibility — the feature itself.
- **Stage A implemented** (worktree `subagent-pool`): `pool.ts` (pure ledger + dispatcher shell),
  `pool.test.ts` (18), `pool.integration.test.ts` (7, fake host), `process-group.ts` (detached spawn +
  group kill), plus `index.ts` wiring (`pool` parameter, `executePooled` path, `/pool` command, background
  notices, total `runSingleAgent`, `isError` on the batch refusals) and `rpc-launcher.ts` group kill.
  Four tests in `execution.integration.test.ts` fail identically on the pre-change HEAD (verified against
  the base commit) — pre-existing, not regressions. No Loom changes.
- **Two defects the tests caught before shipping**: (a) `settleEntry` moved *terminal* settlements to the
  tail along with retries, scrambling the result order Loom maps to slots — found by the integration
  ordering test, fixed to position-preserving settlement + tail-requeued retries (I13); (b) the retry
  decision ignored the entry-level `retryable` flag, so a failure outcome marked retryable would have
  re-run a descriptor-bearing task — found by the unit test, fixed in `settleEntry`.
- **Review round (standalone review `subagent-pool-review-20261118b`)**: 6 surviving criticals, 0 refuted
  (reproduction and intent lenses upheld all six; security upheld the two kill-path ones and marked the
  rest out of lens). Repair-checked in place:
  1. pooled blocking results are mapped by `payload.index`, so a retry's tail-requeue can no longer shift
     `details.results` (I13 now holds unconditionally; `code-reviewer-1`, `pr-test-analyzer-1`);
  2. the SIGKILL escalation fires unconditionally at the grace deadline in both launch paths and the grace
     is unified at 5 s (`code-reviewer-2`, `silent-failure-hunter-1`'s escalation half, `code-reviewer-3`);
  3. `session_shutdown` awaits a bounded grace+1 s so the escalation is delivered before pi exits
     (I8's shutdown clause; `silent-failure-hunter-1`);
  4. the three test-coverage criticals are closed by new tests: retry order under `maxAttempts ≥ 2`,
     `session_shutdown` killing the child tree, and a throwing launch resolving to a failed result
     (`pr-test-analyzer-1/2/3`).
  37 advisories dispositioned separately (29 accepted, 8 deferred).

## 10. Open items for implementation

Stage A is implemented and merged to `main` (commit `1749af08`); the review round's repairs ride on top of
it. Stage B is unimplemented by design.

1. Background completion messages for *blocking* calls (per-task injected messages) — default **no**,
   background-only (stage A: background notices coalesce on a 1.5 s timer and flush at drain).
2. `PI_SUBAGENT_POOL_CONCURRENCY` ships in stage A (engines differ), default 8 everywhere.
3. Stage B implementation order: (a) `pool-settlement-ledger.ts` pure core + exhaustive reducer tests;
   (b) capability probe + responder registering the ledger store; (c) `dispatchPiSubagentStop` branch on
   `poolState: "running"` (defer, no reconcile/release); (d) settle/drain wiring; (e) in-flight-exclusion
   hook in admission; (f) differential test before enabling background for any governed batch. Also settle
   with the Loom owner: whether stage B relaxes the `removeToolCall` wipe for pool tool calls (so
   non-descriptor launches keep working post-return).
4. Future: reload-survivable queue (monitor-style journal + adoption); per-call concurrency caps.

## 11. Hardening backlog (found while re-reviewing the extension + pool edges)

Prioritized. P0 is required for stage A correctness; P1 hardens existing behavior; P2 hardens the pool /
stage B; P3 is Loom-side and optional. Each P0/P1 item names its evidence.

### P0 — required for stage A

1. **Group kill, everywhere.** ✅ Stage A: `process-group.ts` spawns detached and kills the group; used by
   the JSON path (`index.ts`), the RPC path (`rpc-launcher.ts`), and verified end-to-end by the abort test
   (SIGTERM-ignoring grandchild dies).
2. **`runSingleAgent` is total.** ✅ Stage A: `runSingleAgent` wraps `runSingleAgentUnsafe`; every throw
   becomes a failed `SingleResult`.
3. **Pump reserves before awaiting.** ✅ Stage A: `planLaunches` marks entries `running` in its returned
   state before the shell calls `launch`; the randomized loop asserts `running ≤ cap` after every event.
4. **Shutdown drain is synchronous and bounded (stage B).** `session_shutdown` emits the aborted-slot
   drain before exit; kill timeout ≤ 5 s (I8).

### P1 — existing robustness (independent of the pool)

5. **Bound stderr.** `index.ts:825` accumulates unbounded stderr; a chatty child can balloon memory over a
   long task. Keep head+tail with a truncation marker (~64 KiB combined); same bound for the stdout line
   buffer.
6. **`isError` on the too-many refusal.** `index.ts:1065-1071` returns a plain result; the parent can read
   it as success. Add `isError: true`.
7. **Abort-listener hygiene.** Remove the shared-signal listeners on settle (N tasks share the call signal).
8. **Temp-dir leak on SIGKILL.** `finally` covers normal exits only; optional: pid-stamped temp dirs swept
   at `session_start`.
9. **Late-update proof.** With (2) fixed, assert in integration that no `onUpdate` fires after the tool call
   resolves.

### P2 — pool-specific / stage B hardening

10. **Unknown-ledger events fail closed.** A Loom `/reload` loses the in-memory ledger store; a settle event
    for an unknown `(sessionId, toolCallId)` must be refused with a diagnostic, never auto-create a partial
    ledger. Drain for an unknown ledger takes the staleness reconciliation path.
11. **Re-arm the settlement listener on reload.** Use the `loom-launch-port.ts` global re-arm pattern
    (`__loomSubagentLaunchPortOff`) for the settlement channel, or `/reload` stacks handlers.
12. **Untrusted output labeling + caps in injected messages.** Completion messages carry child output into
    the parent context — label as untrusted data and cap per-task output (head/tail, ~2 KiB) so a 64-task
    pool cannot flood the context.
13. **Drop transcripts after reporting.** Background pool retains `SingleResult.messages` until drain; keep a
    summary + capped final output and release the transcript.
14. **Env override sanitization.** `PI_SUBAGENT_POOL_CONCURRENCY`: values above 64 clamp to 64; non-positive
    or malformed values fall back to 8 (no diagnostic in stage A; the parse is unit-pinned).
15. **`pool` on `chain` is an explicit refusal**, not a silent no-op.
16. **Frozen route decision.** Documented as frozen at enqueue; decide whether non-emission tasks re-resolve
    at launch (queue lag vs batch-model consistency).
17. **Orphan watchdog (optional).** Child-side `PI_SUBAGENT_PARENT_PID` check on an interval (the child
    extension runs in-process) so a SIGKILLed pool parent's detached children exit instead of burning
    tokens. Not v1.

### P3 — Loom-side adjacent (optional)

18. Quiescence refusal copy could point at `/pool` for observability (engine text only).
19. Admission in-flight exclusion and `removeToolCall` relaxation stay scoped to stage B (§4.6.6).
20. Reservation re-stamp at launch remains the fallback if dwell ever bites (§6.2).
21. **One run, one revision (#226 tier-1):** re-validate the admitted revision at each child spawn (or pin
    the child) so queued pool tasks cannot load a moved checkout; the extension keeps the launcher
    `errorMessage` intact so Loom's missing-slot diagnostic can interpolate it (#226 tier-2).
22. **Roster liveness (#227 tier-1):** judge a dead entry by the session's liveness, not the id shape, so a
    hard-killed Pi parent cannot block adoption/helpers forever. Pool-side, prefer group SIGTERM-first
    cancel (§4.8) and never SIGKILL while the parent is alive and settling.

### Test additions implied by this backlog

- Fault injection in the integration harness: hang → abort path; malformed JSON lines → protocol-error path;
  exit-by-signal → signal path; huge stderr → cap; late updates after settle.
- Launcher diagnostics survive: a readiness-refused child's `errorMessage` reaches `SingleResult.errorMessage`
  unchanged (the extension's half of #226 tier-2).
- Randomized scheduler loop (seeded, dependency-free — no fast-check in this repo): random sequences of
  enqueue/settle/abort/cancel, assert I1/I2/I7/I8 and exactly-once terminality at every step.
