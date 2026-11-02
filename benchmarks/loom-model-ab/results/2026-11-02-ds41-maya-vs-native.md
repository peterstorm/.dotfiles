# DeepSeek-V4.1-Flash on Maya versus ds4-native — Loom UI-relay v2 planning benchmark

Date: 2026-11-02. Batch paused after three valid runs and one void (see **Status**).

## Scope

The same checkpoint (DeepSeek-V4.1-Flash-1017) under two engines:

- **`ds41`**: EXL3 3.5 bpw on Project Maya TP2 + DSpark (retired 2026-11-02).
  The valid run is `20261023T055951Z-ds41-5`. Reps 1–4 are VOID; their reasons are
  recorded in each `VOID.md`.
- **`ds41-native`**: the released MXFP4 Experts on ds4-native TP2 + DSpark, Exact
  against the engine's reference, behind Maya's `server.py`. Engine `acb97b8`,
  profile `ds41-1017-native`. Valid runs: `20261102T115612Z-ds41-native-1` and
  `20261102T142910Z-ds41-native-2`. Run `20261102T173405Z-ds41-native-3` is VOID:
  the serving stack cut off a phase child.

All four runs share protocol v2 (`f8d3a66e…`), Loom subject `3de455c`, runtime
`9184eef`, Pi 0.83.0 and the `:max` selector. Each passed the mechanical gate:
graph at execute/Wave 1 with all tasks pending, frozen files intact, no Cortex
recall, and every child attested. The interviews were answered only through
`scripts/interview.sh`; `check` found 0 errors, and each warning is defended in
the run's `interview.md`.

## Scores

Each run was graded twice: once unblinded with the transcript, and once blind
(batch `2026-11-02-ds41`, anonymised by `anonymise.sh`, checklist reset, mapping
opened only after all three scores were saved).

| Run | Unblinded | Blind | **Range** | Discovery, unblinded / blind (FULL-PARTIAL-MISSED) |
|---|---:|---:|---|---|
| `ds41-5` (Maya) | 80 | 77 | **77–80** | 23-3-0 / 23-3-0 |
| `ds41-native-1` | 72 | 76 | **72–76** | 22-4-0 / 21-5-0 |
| `ds41-native-2` | 71 | 75 | **71–75** | 23-3-0 / 22-4-0 |

| Group | ds41-5 (U / B) | native-1 (U / B) | native-2 (U / B) |
|---|---|---|---|
| A Specification /20 | 15 / 15 | 14 / 15 | 15 / 15 |
| B Interview /12 | 5 / 5 | 3 / 5 | 4 / 9 |
| C Architecture /28 | 24 / 25 | 23 / 23 | 22 / 23 |
| D Plan alignment /12 | 8 / 5 | 8 / 7 | 9 / 7 |
| E Decomposition /20 | 18 / 17 | 17 / 17 | 14 / 13 |
| F Process /12 | 10 / 10 | 7 / 9 | 7 / 8 |

The largest disagreement is native-2's interview (4 unblinded, 9 blind). The
blind grader saw one genuine question. The unblinded grader saw, in the
transcript, that the parent had written its own "Interview answers (already
recorded)" into the specify prompt and pre-resolved the approach gate, so it
gave no credit for the economy. The transcript is the better evidence here.

### Against the earlier v2 arms (one run each, unblinded)

| Arm | Total | Discovery (FULL-PARTIAL-MISSED) |
|---|---:|---|
| **DeepSeek-V4.1-Flash on Maya** | **77–80** | 23-3-0 |
| GPT-5.6 Sol | 78 | 22-4-0 |
| **DeepSeek-V4.1-Flash on ds4-native** | **71–76** (2 runs) | 21–23 full |
| GLM v10 | 69 | 23-3-0 |
| DS4 Vision r21 | 69 | 18-8-0 |
| Qwen Flash-Next v2 | 63 | 23-3-0 |

DeepSeek-V4.1-Flash is the strongest local planner measured on v2. Its best
run matches or beats Sol, and both native runs beat GLM v10 and DS4 Vision.

## What the runs share (the model, not the engine)

- **The same worst defect in all three.** `agent_settled` emits `observe-event`,
  and a `child-exited` before settlement emits no `terminate-child`. Frozen v2
  wants neither: settlement is unobserved, and an early exit terminates and fails
  closed. Every grader marks FR-038, FR-039 and FR-040 PARTIAL. native-1 adds
  FR-035: answers for ids seen but no longer pending get `response-mismatch`
  instead of `unknown-request`.
- **The same false premise in the oversize loop-back.** All three amended the
  spec on the claim that a discard-until-LF state cannot be represented in the
  frozen carry. The amended spec lets an oversized record's well-formed tail
  become a frame.
- **Strong framing and decomposition.** ds41-5 and native-1 each decompose to
  one task over exactly the two allowed files (E 17–18/20).

## Where the native runs lost points (model behaviour, recorded as such)

- **Invented interview answers.** native-1's parent wrote 12 "operator rulings"
  into the architecture prompt, among them "90%+" and "ts-pattern allowed",
  against the key's every-branch bar and "standard library only". native-2's
  parent wrote the specify and architecture interviews itself. It told the
  agents not to ask, and the architecture agent reported an approach "picked at
  the gate" that nobody saw. VOID native-3 did the same ("DO NOT CALL
  AskUserQuestion — headless run"). Maya's ds41-5 asked its 40 questions. With
  two native runs and one Maya run, this may be sampling variance rather than the
  engine. The weights differ (MXFP4 against EXL3 3.5 bpw), but the behaviour is
  the model's.
- **Scope.** native-2 added four ADR tasks in wave 2, against its own two-file
  scope (E 13–14). It also created a real GitHub issue, `peterstorm/loom#142`,
  which is still open.
- **Probe files.** Children wrote and deleted test files under `engine/` during
  planning: `zz-discovery-probe.test.ts` in native-1, and three `__probe` files in
  native-2. Graders took a point under F1; the mechanical gate cannot see a file
  that was deleted again.
- **Loop-backs.** native-2 needed three plan-alignment loop-backs before a clean
  pass (2 h 46 min). native-1 needed one (2 h 16 min), as did ds41-5 (~1 h 27 min).

## Serving-stack limits found in this batch (not model quality)

1. **A 32,768-token reply cap** (`pi/models.json` `maxTokens`, shared by every
   arm). Maya's thinking budget clamps it to 24,576 tokens of reasoning. Replies
   in this batch reached 29,990 and 31,291 tokens. It is now 262,144, with
   `thinking_budget` 262,144: a reply is bounded by the context, less the quarter
   Maya keeps for the answer.
2. **No bytes for more than 300 s during a large `write`.** `server.py` holds a
   DSML parameter until it is complete and sends keep-alives only while the
   engine is idle. native-3's architecture child (11K tokens of reasoning, then a
   ~20K-token file) was cut by Node's fetch body timeout after 512 s. The fix is
   `scripts/inference/deepseek/ds41-1017-native/maya-serve-keepalive.patch`, with
   a regression test (0 keep-alives before, ≥3 after; 188 of Maya's serve tests
   green), applied to a copy of the pinned checkout by `--install`.
3. **A parent re-reads its whole context after a subagent** (122,276 tokens in
   50 s in native-1). This happens when its last reply re-renders differently and
   the subagent's turns have evicted its prompt-end Rewind point. The fix is in
   ds4-native: a checkpoint keeps its turn rings. The core is tested; the GPU
   build and serve-check are pending.

None of these changes the tokens the model writes (the engine is Exact). Items 1
and 2 cut replies, so they decide whether a long reply survives; item 3 costs
wall time only.

## Speed surface (separate from quality)

The bench is `bench-ds41-1017-maya.sh BENCH_MODEL=deepseek-v4.1-flash-native`
with synthetic filler.

| | ds4-native | Maya (runbook) |
|---|---|---|
| Prefill, 6K / 20K / 60K / 120K / 230K | 2,030 / 4,110 / 4,700 / 4,650 / 4,470 tok/s | 1,035 / 1,541 / ~1,590 / — / ~1,708 (205K) |
| Decode, short prompt, warm | 105–106 tok/s | 102–103 |
| Decode, 512 tokens after each long prefill | 66–74 tok/s | 83–104 |

Real agent traffic reads more slowly than the synthetic filler suggests: 5–13K
reads of code and tool output ran at 600–1,200 tok/s. The filler's 12-word
vocabulary keeps its routing cache-hot. `BENCH_CORPUS` now builds prompts from
real files, but it has not been run yet.

## Status

Paused 2026-11-02 at the user's request, with the desktop powered off. Still to
do before rep 4:

- Run `--install` with the patched server, and build the ds4-native fix and
  verify it on the GPUs.
- Run rep 4 of `ds41-native` on the unhamstrung stack.

Isolation is still off (Pi has no Cortex or Obsidian, and Loom is pinned to
`9184eef`). Run `scripts/isolation.sh on` after the batch.

## Evidence

- `runs/<run>/{rubric-score.md,discovery-checklist.tsv,outcome.planning.json,model-attestation.json,interview.md,session.jsonl}`
- `blind/2026-11-02-ds41/arm-{A,B,C}/rubric-score.md` and `blind/2026-11-02-ds41.mapping.txt`
- `runs/20261102T173405Z-ds41-native-3/VOID.md`
