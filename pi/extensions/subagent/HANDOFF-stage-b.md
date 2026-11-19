# Subagent pool — stage A state & stage B handoff

Status snapshot for a fresh session picking up the pool work. Written 2026-11-18, after the
stage-A review-and-fix cycle completed. Read alongside `DESIGN-pool.md` (design + invariants).

## 1. Where things stand

| Item | State |
|---|---|
| Stage A implementation | **Merged & pushed.** `1749af08` (stage A) + `6216635c` (review repairs) on `peterstorm/.dotfiles` `main` |
| Review | `subagent-pool-review-20261118b` — **6 surviving criticals, 0 refuted**; result digest `c775d1e2cb70be3817b3a570b171ca1752ab79f7071658070ce308ef28f48d31` |
| Disposition | `subagent-pool-disposition-20261118` — 37 advisories: **29 accepted / 8 deferred**, digest `ea3bc6c8886424b94f680c20709eaca7f912c2be76990a263cbd44c34ac5a764`; published at `.claude/reviews/review-and-fix-runs/subagent-pool-disposition-20261118/artifacts/disposition.json` (gitignored — runs root is "runtime, not persisted" by `.gitignore` policy) |
| Deployment | `~/.pi/agent/extensions` is a **symlink** to `~/.dotfiles/pi/extensions` — the committed tree IS the installed extension. No copy step. A running pi session needs `/reload` (or `reload_runtime`) to pick up new extension code |
| Tests | Pool suite **34/34** (23 unit in `pool.test.ts`, 11 integration in `pool.integration.test.ts`). Full extension suite: 92 pass / 4 fail — the 4 failures are pre-existing `execution.integration` failures (`resolves relative item cwd identically…`, `never marks task-refuse after the Task RPC prompt write`, `never marks task-hang after the Task RPC prompt write`, `marks cancellation before Task write but not cancellation after Task write`), identical on the pre-change HEAD. **Not regressions** |

Run both suites from the checkout:

```
cd ~/.dotfiles/pi/extensions/subagent
bun test pool.test.ts pool.integration.test.ts   # 34
bun test .                                        # full suite (96 tests, 4 pre-existing fails)
```

## 2. What stage A delivers (operational)

- `pool: true` / `pool: {}` on the `subagent` tool: blocking pooled call through a **process-wide**
  dispatcher — global cap (default 8, `PI_SUBAGENT_POOL_CONCURRENCY`, clamped >64→64, malformed→8),
  FIFO queue, a freed slot serves the next queued task from any call immediately (no batch barrier).
- `pool: { maxAttempts: 1..3 }`: engine-authorized **process-level** retry only (non-zero exit, not
  aborted); semantic failures (exit 0) stay the engine's; Loom emission tasks are single-use.
  Retries dispatch mid-wave on the next freed slot.
- `pool: { background: true }`: returns immediately with a snapshot; completions arrive as coalesced
  messages (1.5 s timer, steer + triggerTurn). **Refused fail-closed for Loom-governed tasks** in
  stage A (`looksLoomGoverned` heuristic on task text). Stage B replaces the heuristic with a probe.
- Result order: `details.results[i]` is task i **unconditionally** — `orderedPooledResults` maps by
  `payload.index` (I13), so a retry's ledger tail-requeue cannot shift results.
- Kill semantics: children spawn detached (own process group); cancel/abort sends group SIGTERM then
  an **unconditional** group SIGKILL at `GROUP_KILL_GRACE_MS` (5 s, unified for the JSON path in
  `index.ts` and the RPC/emission path in `rpc-launcher.ts`). `session_shutdown` is async and awaits
  grace+1 s so the escalation fires before pi exits (I8).
- Operator surface: `/pool` (status), `/pool cancel <taskId|all>`.
- Retry policy lives in one pure function: `classifyPoolAttempt` (`pool.ts`), unit-tested as a table.

## 3. Stage B — what it is and the two-sided split

Goal: Loom hands a whole wave (20+ dispatches) to **one** pooled background call; the tool result
carries `results: []` + `poolState: "running"` (I12); Loom defers settlement; the extension emits a
drain event; Loom reconciles on drain. **Stage B is unimplemented by design — nothing exists yet on
either side** (verified against loom `0cda5b1c`).

### Pi extension side (`~/.dotfiles/pi/extensions/subagent/`) — mechanical half

- **(a)** `pool-settlement-ledger.ts` — pure settlement ledger ADT + exhaustive reducer tests
  (DESIGN-pool.md §10 item 3a).
- **(b)** Capability-probe responder: answer Loom's `loom:pool-settlement:v1` probe at admission;
  register the ledger store for the call; replace the `looksLoomGoverned` heuristic with the probe
  answer; allow Loom-governed **background** once the probe path exists.
- **(b′)** Emit the drain/settlement event; carry `poolState: "running"` in the background result
  details (the I12 shape).

### Loom side (`~/dev/claude-plugins/loom`) — correctness-critical half

- **(c)** Defer branch in `pi/subagent-stop.ts`: a tool result with `poolState: "running"` → defer
  capture, no reconcile/release. This file is still the seam after today's PRs (see §4).
- **(d)** Settlement handler: receive drain events, reconcile, release reserved requests. The
  correctness-critical piece (exactly-once settlement, ordering — review-and-fix evidence depends on it).
- **(e)** In-flight-exclusion hook in admission/quiescence: a deferred-but-running dispatch counts as
  live. **The mixed-wave risk**: a run where some dispatches run on Claude Code and some on pooled pi
  calls must treat "harness without pool" as always-settled-from-result while pool-pending pi
  dispatches are live. A wave hanging quiescence because one side miscounts is the real failure mode —
  test this hardest.
- **(f)** Differential test (acceptance gate): same wave with the probe answered vs. probe absent;
  the probe-absent transcript must be byte-identical to the current engine's issuance/settlement.
  Lives in Loom's test suite. **If it diverges, stage B does not ship.**

### Claude Code compat guarantees (verified design, restated)

1. Pool lives in the pi extension only; Claude Code's native Task path is untouched.
2. Deferred settlement is **probe-gated** (I11): only the pi extension answers the probe; absent or
   mismatched probe ⇒ today's barrier-batched behavior byte-for-byte.
3. The settle branch keys on the `poolState: "running"` result shape only the pool produces (I12);
   anything else flows through unchanged reconciliation. A missing branch terminalizes loudly, never hangs.

### Ship sequence (each step shippable alone, fail-closed throughout)

1. Loom issues the probe; "no answer" ⇒ today's path. (Loom-only, zero behavior change.)
2. Pi answers the probe + ledger. (Pi-only, still unused by Loom.)
3. Loom defer branch + drain handler **behind the probe**. (Still fail-closed.)
4. Differential test green ⇒ governed background enabled.

## 4. Loom fact-check after 2026-11-18's PRs (basis: `98a9852c` → `0cda5b1c`)

Six PRs merged today: #230 (README feature/guard map), #231 (mermaid phase-id rendering), #232
(docs audit sweep), #234 (reopen names what the Finding needs — #213 Cause 3), #233 (re-reviewed
Task's roster follows what changed — Cause 5b), #229 (owner verification at Task stop — Cause 2,
ADR-0092), plus docs cleanup f1b1f4ff. **Facts verified unchanged:**

- `pi/subagent-result-route.ts` (result-index→slot binding): byte-unchanged — I13 impact analysis holds.
- **No pool-settlement / `poolState` / pool capability-probe code exists in Loom** — stage B fully
  unimplemented there, as assumed. (The only "capability probe" is the pre-existing emission-launcher
  one in `pi/emission-launch-bridge.ts`.)
- `engine/src/core/roster-liveness.ts`, admission/quiescence, the standalone-disposition machine: unchanged.
- `pi/subagent-stop.ts` gained an additive `taskOwnerCheck` threaded through stop-checks (same shape
  as the existing `taskMutation` check); the **defer branch seam is intact** — stage B adds a branch,
  it does not disturb the new check.

## 5. Operational gotchas (learned the hard way today)

- **Loom version skew**: any Loom CLI mutation refuses when the running pi's in-memory runtime
  revision differs from the checkout on disk. Fix: `~/dev/claude-plugins/loom/scripts/sync-pi-agents.sh`
  (agent definitions change with PRs — 31 changed today) **then `reload_runtime()`**, and let the turn
  settle so the queued reload fires. The reload-autocontinue extension confirms with
  `[runtime-reloaded] Continue from where you left off.`
- **Standalone-review scope freezes against `origin/main`**: a review of the tip commit that is
  already pushed freezes an empty scope ("No scoped file has a text diff"). Workaround used for
  `…-20261118b`: pin the local ref for the duration of `start` only —
  `git update-ref refs/remotes/origin/main <parent-sha>` → run start → restore. The scope freezes at
  start; restore immediately after.
- **Spawn volume**: the review's 7 slots can be run 3 at a time (user preference: cap at 3 during
  working hours; up to 8 otherwise). The engine accepts results via native capture; the parent
  confirms each slot with an idempotent
  `helper orchestration submit --request <id> --slot <id> --attempt <n> < result.json` (exact bytes
  the subagent returned). Refutation verdicts submit the same way.
- **Disposition is no-agent**: `helper orchestration start standalone-disposition --runs-root <root>
  --run <new-run-id> < input.json`, input = `{source:{locator,runId,resultDigest}, record:{schemaVersion:1,
  source, provenance:"DECLARED", revision:{kind:"initial"}, entries:[{origin,digest,decision,reason}…]},
  previous:null}`. `origin` digests come from `helper orchestration inspect --lineage` →
  `.advisoryInventory` (canonical inventory order; every advisory exactly once). The start command
  drives registration → artifact → receipt → done in one call.
- **Conventions**: commits go directly on `main` in `~/.dotfiles` (implement in a worktree only if a
  repo is shared with live sessions); Loom work goes in a worktree per the loom plugin's own rule.
- **Type-check sandbox**: `/tmp/subagent-tscheck` (strict tsconfig, symlinks to pi 1.5.2 packages,
  typebox 1.3.27). `/tmp` may not survive a reboot — recreate if missing. Known pre-existing errors
  only: `proc.stdout/stderr/stdin possibly null` (rpc-launcher), `t` unknown in index.ts parallel
  path, model-routing test brands.
- **Lint reminder standing offer**: `~/.dotfiles` has `boundaries`, `pureModules`, `requireGovernance`,
  `docReferences` off with no recorded reason. Either
  `bun ~/dev/claude-plugins/loom/scripts/lint-project.ts --init` (infer + baseline) or record declines
  in the rules directory's `config.json`. Unresolved as of this writing.
- Pre-existing lint debt in the subagent extension: `max-function-lines` on `execute`, `renderResult`,
  `runRpcAgent`, `loadAgentsFromDir`, and now `executePooled` (113 lines) / `createDispatcher`
  (~150 lines). Baseline candidate, not addressed in stage A/repairs.

## 6. Deferred advisories (8) — the P1/stage-B backlog

Each has a one-line reason in the published disposition; restated here as backlog:

1. `silent-failure-hunter-6` — signal-delivery reporting (EPERM vs reaped); the unconditional 5 s
   SIGKILL backstops it. P1.
2. `pr-test-analyzer-5` — RPC/emission launch-path abort test (needs emission fake-child harness).
3. `pr-test-analyzer-10` — `/pool` command-path test (needs harness registerCommand capture).
4. `type-design-analyzer-1` — carry the full observed `SingleResult` on mid-run aborts (stage-B
   report fidelity; reason-carry + never-launched distinction already shipped).
5. `type-design-analyzer-2` — exitCode -1/0 sentinel → status discriminator (display-only during flight).
6. `type-design-analyzer-3` — PoolEntry settled⇔outcome as a discriminated union (deepen-level).
7. `type-design-analyzer-7` — type the detached-spawn/group-kill pairing (deepen-level).
8. `architecture-tech-lead-5` — retire `mapWithConcurrencyLimit` behind a per-call dispatcher
   isolation mode (the documented stage-B consolidation).

## 7. Key paths

- Design + invariants: `~/.dotfiles/pi/extensions/subagent/DESIGN-pool.md`
- Pool core/shell: `pool.ts` · tests: `pool.test.ts`, `pool.integration.test.ts`
- Wiring: `index.ts` (`executePooled`, `orderedPooledResults`, shutdown handler, `/pool`)
- Process groups: `process-group.ts` (`GROUP_KILL_GRACE_MS = 5_000`, `spawnDetachedOptions`,
  `killProcessGroup`); RPC path: `rpc-launcher.ts`
- Loom defer seam (stage B): `~/dev/claude-plugins/loom/pi/subagent-stop.ts`
- Loom result binding: `~/dev/claude-plugins/loom/pi/subagent-result-route.ts`
- Runs root: `~/.dotfiles/.claude/reviews/review-and-fix-runs/` (gitignored)
- This doc: `~/.dotfiles/pi/extensions/subagent/HANDOFF-stage-b.md`
