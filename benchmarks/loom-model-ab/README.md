# Loom local-model benchmark — planning that survives implementation

An experiment that answers one question: **which local model should drive a
Loom feature run end to end?** Every arm gets the same meaningful TypeScript
JSONL relay/reducer task, writes its own spec and plan, decomposes, implements,
and passes the wave gate. The plan is not graded as prose alone: a hidden suite
checks whether it survives implementation against requirements the model never
sees.

The benchmark supports DeepSeek V4 Flash, Qwen3.8-27B, and both immutable
GLM-5.3 Flash v84 speculation profiles. This remains one frozen experiment—not
a second GLM-specific task—so results inside a protocol hash remain comparable.

## Why this is measurable at all

`pi/model-routing.json` carries one rule:

```json
{ "id": "local-workloads-use-parent", "when": { "parentClass": "local" }, "use": { "kind": "parent" } }
```

`desktop-vllm/*` is class `local`. So when the **parent** Pi session runs on a
`desktop-vllm` model, every Loom child Agent — specify, architecture, decompose,
implementer, reviewers, wave gate — inherits it. Loom's own profile catalog only
knows `openai-codex` targets, and this rule is exactly the documented escape
hatch ("the launcher's explicit routing decision determines the effective
model", `docs/model-profiles-and-calibration.md`).

That makes the whole pipeline swap on one flag. Both Pi child transports must
apply the same effective binding: ordinary `subagent` children and Loom's
interactive RPC phase children. Every completed run is checked by
`scripts/verify-run-models.sh`; missing routing evidence or one mismatched child
voids the repetition rather than silently attributing another model's work to
the arm.

The routing policy also publishes exact named `qwen` and `glm` targets beside
parent inheritance. They are explicit provider/model/thinking bindings for
workload-specific rules; the benchmark itself continues to inherit the active
parent so one arm selector controls the whole run.

## Arms

| Arm | Pi launch selector | Context | Immutable runtime profile |
|---|---|---:|---|
| `ds4` | `desktop-vllm/deepseek-v4-flash:max` | 1,048,576 | `ds4-infernal-invocation-cu133-r18` |
| `qwen` | `desktop-vllm/qwen3.8-27b:xhigh` | 262,144 | `qwen38-27b-bf16-dspark-sglang-v2` |
| `glm-dflash` | `desktop-vllm/glm-5.3-flash-exl3-k4-vision:max` | 98,304 | `glm53-flash-exl3-k4-vllm-sm120-v3` |
| `glm-mtp` | `desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max` | 393,216 | `glm53-flash-exl3-k4-vllm-sm120-v5` |

The catalog is machine-readable through `bash scripts/run-arm.sh --list`. The
canonical GLM model-quality arm is `glm-mtp`; use `glm-dflash` for a matched
runtime-profile comparison, not as a second independent model.

### Three asymmetries that must be stated, not hidden

**Thinking level cannot be equalised.** The `thinkingLevelMap` entries that are
non-null differ: DS4 and GLM expose `low`/`high`/`max`, while Qwen exposes
`low`/`xhigh`. A mapped-null level is *not rejected*—Pi silently falls back, so
a run pinned to a level one model does not support looks valid but is not the
run you think it is. Each arm therefore runs at **its own maximum**, pinned on
the command line. This compares each model at its best; it does not compare
equal reasoning budgets.

**Context windows differ.** GLM MTP gets 393,216 tokens, Qwen gets 262,144,
DS4 gets 1,048,576, and the rollback DFlash profile remains at 98,304. Do not
treat context exhaustion as a spoiled run—it is a result. Record `context_exhausted: true` and retain the
sample. A model that cannot hold a Loom phase in its deployed context is
answering the operational question.

**GLM speculation modes are not different base models.** `glm-dflash` and
`glm-mtp` use the same EXL3 target weights, image family, template, and reasoning
level, but the qualified launch envelopes now differ in both speculation and
context. Treat them as runtime-profile evidence (correctness, stability,
latency), not a controlled speculation A/B or extra independent observations
about GLM planning quality.

## Isolation

Arms and repetitions must not be able to see each other's work. Four channels,
three of them non-obvious:

1. **Filesystem** — each run gets its own git worktree off the same base commit:
   `git worktree add ../loom-bench-<run-id> -b bench/<run-id> <BASE_SHA>`.
   The worktree is destroyed after the diff is captured.
2. **Cortex memory — the dangerous one.** Cortex recalls into every session and
   extracts from every transcript. Without intervention, arm 1's design
   decisions are recalled as authoritative context inside arm 2, and the leak is
   invisible because it arrives inside a `<system-reminder>`. Disable extraction
   and recall for the whole benchmark, or point `CORTEX_DB` at a scratch
   database that is deleted between runs. **Verify by grepping the run
   transcript for `CORTEX_MEMORY_START` — if it appears, void the run.**
3. **Loom state and GitHub** — Loom creates an Issue and writes
   `.claude/specs/<feature>/`. Two runs sharing either will collide. The
   worktree gives a fresh `.claude/`; run with Issue creation disabled, or let
   each run create its own and record the number.
4. **Prefix cache** — not contamination, but it does distort latency. Only
   compare wall-clock across runs of the same arm, never across arms.

Port 8000 is exclusive, so arms cannot run concurrently. Batch by arm and swap
the backend once per batch. Batching confounds arm with time-of-day and machine
state—accept it, note host changes, and never cross a driver, firmware, Pi,
protocol-hash, or Loom-baseline change inside one batch.

### Swapping the backend

Use each versioned profile's attended switch path. Port 8000 remains exclusive;
never improvise a second launch over a running profile:

```bash
# → GLM v84 MTP3 384K (canonical GLM quality arm)
bash scripts/inference/glm53/switch-glm53-exl3-profile-v5.sh start

# → GLM v84 DFlash2 (matched runtime-profile arm)
bash scripts/inference/glm53/switch-glm53-exl3-profile-v3.sh start

# → Qwen (stop a non-Qwen profile first; this switcher fails closed on port conflicts)
bash scripts/inference/qwen38/switch-qwen38-backend-v4.sh sglang

# → DS4 (stop the current mutually-exclusive :8000 profile first)
bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
```

Then run `bash scripts/run-arm.sh --probe <arm>`. It refuses stale Loom
baselines, active Cortex memory, malformed/multi-model responses, failed
authentication, and served-model mismatches. Health alone has already lied once
during a cutover.

## Repetitions

Three per arm. That is enough to separate a model that fails a requirement every
time from one that fails it once, and it is not enough for a significance claim
on anything graded by judgement.

Report accordingly:

- **Mechanical outcomes** (typecheck clean, own tests pass, hidden tests passed,
  wave gate passed, frozen file untouched, scope respected) — report as counts
  out of 3. These are binary and usually separate cleanly.
- **Judged quality** — report as a range across repetitions with the spread
  shown, never as a mean of three numbers presented as a measurement.

A split result (2/3 vs 3/3) is a signal to run more repetitions, not a winner.

## Grading

Four instruments, in decreasing objectivity. Run them in this order and do not
let a later one overturn an earlier one.

**1. Hidden acceptance suite** — `hidden/ui-relay.hidden.test.ts`, written
before either arm ran, traced test-by-test to `hidden/reference-spec.md`. Copy
it into the finished worktree, run it, record pass/fail per requirement, then
delete it. It imports the frozen signatures, which is the entire reason the
types file is frozen and given as an input.

> This is I2 — *"Types first, as a wave-0 artifact"* — from
> [[loom-deterministic-implementation]], used as an experimental control rather
> than as a determinism measure. I2's claim is that "the types *are* the task
> contract"; if that holds, two models handed the same frozen contract produce
> implementations that one suite can grade, and the benchmark is possible. If it
> does not hold, the arms diverge on API shape and nothing here works. Either
> way the run tells you something about I2 as well as about the models.
>
**Calibrated floor.** The suite is 52 tests. Run against a stub that implements
`parseRequestId` and returns empty results from everything else, it scores
**12/52** — and all 12 are honest passes, not false positives (the stub really
does parse ids, really doesn't throw, and a no-op reducer really is
deterministic). So 12 is the do-nothing baseline: an arm scoring near it has
produced nothing, and any score must be read against 12, not against 0. Re-run
this calibration whenever a test is added.

> Note what is deliberately **not** supplied: I4 exemplar anchoring. The brief
> gives no "closest existing module" to imitate, so idiom variance stays in the
> measurement. That is intentional — idiom discipline without an exemplar is a
> real difference between these models, and handing over an exemplar would mask
> it. If you later want to measure I4's value, re-run one arm with exemplars
> added and compare against its own baseline.

**2. Requirement discovery** — for each FR in the reference spec, mark three
independent facts: did the arm's own `spec.md` state it, did `plan.md` account
for it, does the implementation satisfy it. Discovery and satisfaction are
scored separately. Passing a requirement you never identified is luck; stating
one precisely and then failing it is a different defect. This column is the
reason the models write their own spec — it measures whether the model *found
the problem*, which is most of what a spec phase is for.

**3. Mutation score** — every arm writes its own tests, and "tests pass" is
gameable by writing vacuous ones. Run mutation testing over `ui-relay.ts` using
only the arm's own suite. A high hidden-suite score with a low mutation score
means the implementation is good and the tests are theatre; report both.

**4. Blind rubric** — `rubric.md`, scored from an anonymised diff. See below.

### Blinding

The grader knows these models' reputations, and that is a bias with a known
direction. Before grading:

```bash
bash scripts/anonymise.sh   # emits arm-A / arm-B, mapping written to a file the grader does not open
```

Grade every artifact under the anonymous label. Reveal the mapping only after
every score is written down and saved. If the grader has already seen a run's
transcript live, that run is unblinded — record it as such rather than
pretending otherwise.

### Voiding a run

Void and re-run only for: a harness crash unrelated to the model, a backend that
died mid-run, cortex recall observed in the transcript, child-model routing
that is missing or differs from the arm selector, or operator error answering
off-script. **Do not void** for: context exhaustion, a model that
loops, a model that edits the frozen file, a model that gives up. Those are
results, and discarding them is how a benchmark ends up measuring nothing.

## Layout

```
frozen/                   identical in every arm
  brief.md                the verbatim /loom argument
  ui-relay-types.ts       frozen wave-0 contract, copied into the worktree
  answer-key.md           the operator's scripted interview answers
hidden/                   never enters a worktree
  reference-spec.md       the answer key: FRs + discovery checklist
  ui-relay.hidden.test.ts the acceptance suite
rubric.md                 blind scoring sheet
runs/<run-id>/            per-run record: diff, artifacts, interview log, scores
```

## Running a batch

**Once, before the first run:**

```bash
bash scripts/verify-harness.sh     # catalog, Pi maps, hidden FR parity, baseline
bash scripts/isolation.sh off      # unregister cortex; keeps a backup
bash scripts/isolation.sh status   # must say "safe to run"
bash scripts/run-arm.sh --probe glm-mtp
```

If verification reports a stale baseline, refresh it with
`bash scripts/baseline.sh`, commit that receipt with the harness change, and
verify again. Never compare runs carrying different `protocol_sha256` values.

**Per run:**

```bash
bash scripts/run-arm.sh glm-mtp 1
```

It refuses to continue unless `:8000` is authenticating and serving the arm's
model, then creates the worktree, commits the frozen types, and records
`base_sha`. Follow the instructions it prints:

```bash
cd <worktree>
pi --model desktop-vllm/deepseek-v4-flash:max
```

Pin the model and level on the command line even though pi has defaults —
`~/.pi/agent/settings.json` currently defaults to `qwen3.8-27b` at thinking
level `high`, which is a **mapped-null** level for Qwen and silently falls back.
An unpinned run is not the run you think it is.

In the session: `/loom` with `frozen/brief.md` pasted verbatim. Answer only from
`frozen/answer-key.md` and log every exchange to `runs/<run-id>/interview.md`.

**After each run**, copy into `runs/<run-id>/`: `spec.md`, `plan.md`, the task
graph, the wave-gate result, and the session transcript path and wall-clock.
Then:

```bash
bash scripts/verify-run-models.sh runs/<run-id>  # every child must match run.json.model
bash scripts/grade-implementation.sh <worktree> runs/<run-id>
grep -l CORTEX_MEMORY_START <transcript>        # any hit voids the run
git -C ~/dev/claude-plugins/loom worktree remove <worktree>
```

**Once, after the last run:**

```bash
bash scripts/isolation.sh on                       # restore cortex
bash scripts/anonymise.sh batch-1 runs/2026*       # then grade blind
```

## Recording an outcome

Record these as **independent** facts, never collapsed into one verdict — a
process can time out and still exit 0, and a suite that was killed must never
read as a suite that passed:

```json
{
  "run_id": "...", "arm": "ds4", "base_sha": "...", "wall_clock_s": 0,
  "phases_completed": ["specify", "architecture", "decompose", "execute"],
  "context_exhausted": false, "looped": false, "gave_up": false,
  "frozen_file_intact": true, "scope_respected": true,
  "child_models_attested": true,
  "typecheck_clean": true, "own_tests_pass": true, "own_test_count": 0,
  "wave_gate_passed": true, "hidden_suite": { "passed": 0, "failed": 0 },
  "mutation_score": 0.0, "voided": false, "voided_reason": null
}
```
