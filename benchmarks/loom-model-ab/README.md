# Loom local-model benchmark — implementation-ready planning

A planning-only experiment that answers: **which local model produces the most
correct, implementation-ready Loom plan?** Every arm gets the same meaningful
TypeScript JSONL relay/reducer task and runs through:

1. brainstorm;
2. specification;
3. architecture;
4. plan alignment; and
5. decomposition.

The run stops immediately before Wave 1. No implementer, test, reviewer, or
wave-gate child runs, and no production or test file may change.

The benchmark supports DeepSeek V4 Flash, two immutable Qwen3.8-27B runtime
profiles, the experimental Qwen3.8 Flash-Next FP8 runtime, and three immutable
GLM-5.3 Flash v84 runtime profiles. Results are comparable only when both
`protocol_version` and the complete protocol SHA match.

## Protocol versions

- **v2 (default):** aligns the visible contract, hidden reference, and executable
  suite with Loom's shipped Pi 0.83.0 `extension_ui_request` RPC wire. Its source
  provenance is pinned in `protocols/v2/source-lock.json`, and its raw schema is
  explicit model-visible input rather than hidden grader knowledge.
- **v1 (retired):** preserved byte-for-byte at the original `frozen/`, `hidden/`,
  and `rubric.md` paths. Its brief named the shipped Pi envelope while its hidden
  answer expected a synthetic direct-method grammar. Historical v1 scores remain
  reproducible measures of that protocol, but they are not evidence of current
  Loom implementation readiness and must not be compared with v2 totals.

Do not mutate a protocol in place. Add a new version whenever the task contract,
answer key, hidden requirements, or rubric changes.

## Why this is measurable

`pi/model-routing.json` routes local parents through the parent binding. When
the parent Pi session uses a `desktop-vllm/*` model, every planning child must
inherit that exact provider/model/thinking selector. Both ordinary subagents
and interactive RPC phase children are checked by
`scripts/verify-run-models.sh`; missing or mismatched routing evidence voids the
run.

The benchmark has a hidden reference specification. Grading records three
separate discovery facts for every FR:

- did `spec.md` discover it?
- did `plan.md` account for it?
- did the task graph preserve it?

This measures planning directly. No implementation is generated or inferred.

## Arms

| Arm | Pi launch selector | Context | Immutable runtime profile |
|---|---|---:|---|
| `ds4` | `desktop-vllm/deepseek-v4-flash:max` | 1,048,576 | `ds4-infernal-invocation-cu133-r18` |
| `qwen` | `desktop-vllm/qwen3.8-27b:xhigh` | 262,144 | `qwen38-27b-bf16-dspark-sglang-v2` |
| `qwen-vllm-bf16kv` | `desktop-vllm/qwen3.8-27b:xhigh` | 262,144 | `qwen38-27b-bf16-dflash2-vllm-v3` |
| `qwen-flash-next` | `desktop-vllm/qwen3.8-flash-next-fp8:xhigh` | 262,144 | `qwen38-flash-next-fp8-vllm-v1` |
| `glm-dflash` | `desktop-vllm/glm-5.3-flash-exl3-k4-vision:max` | 98,304 | `glm53-flash-exl3-k4-vllm-sm120-v3` |
| `glm-mtp` | `desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max` | 393,216 | `glm53-flash-exl3-k4-vllm-sm120-v5` |
| `glm-fp8` | `desktop-vllm/glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k:max` | 393,216 | `glm53-flash-exl3-k4-vllm-sm120-v6` |

List the machine-readable catalog with:

```bash
bash scripts/run-arm.sh --list                 # default v2
bash scripts/run-arm.sh --protocol v1 --list  # historical reproduction only
```

`qwen-vllm-bf16kv` measures the single-GPU vLLM DFlash2/BF16-KV profile;
`qwen` remains the historical TP2 SGLang/DSpark arm. `qwen-flash-next` measures
the experimental TP2 FP8 profile with its 51.2B-element PLE table in host RAM.
`glm-fp8` follows the active canonical GLM route. `glm-mtp` remains the
multimodal v5 comparison arm, and `glm-dflash` is runtime-profile evidence—not
an independent base-model observation.

### Asymmetries that remain part of the experiment

- **Thinking levels differ.** Each arm runs at its own highest supported mapped
  level. Pi silently falls back for mapped-null levels, so selectors are pinned.
- **Context windows differ.** Context exhaustion is a result, not a void reason.
- **GLM speculation profiles differ in context as well as speculation.** They
  are not a controlled speculation-only A/B.

## Valid terminal state

A planning run is complete only when all of the following hold:

- brainstorm, spec, plan, plan-alignment, and task graph exist;
- the graph has `current_phase: "execute"` and `current_wave: 1`;
- every task remains `pending`;
- `executing_tasks` is empty;
- no wave gate has implementation, review, or test evidence;
- no file outside `.claude/` changed after the frozen baseline;
- the frozen types file is byte-identical;
- the transcript contains no Cortex recall;
- at least one planning child ran, every child matches the arm selector, and no
  implementer, test, reviewer, ADR-writer, or wave-gate child appears.

Entering `current_phase: "execute"` records that decomposition completed. It
does **not** authorize Wave 1. If any task starts, preserve the artifacts and
mark the repetition invalid; do not silently treat partial implementation as a
planning result.

## Isolation

Arms and repetitions must not see each other’s work:

1. **Filesystem:** each run gets a fresh git worktree from one recorded Loom
   base commit.
2. **Cortex:** disable recall and extraction for the entire batch. Any
   `CORTEX_MEMORY_START` in `session.jsonl` voids the run.
3. **Loom state/GitHub:** each worktree owns fresh `.claude/` state. Keep Issue
   creation disabled or record the unique issue.
4. **Runtime:** port 8000 is exclusive. Arms cannot run concurrently.

Batching confounds arm with time-of-day and host state. Never cross a driver,
firmware, Pi, protocol-hash, or Loom-baseline change inside one batch.

## Backend switching

Use only attended, versioned switch paths:

```bash
# Active GLM text FP8 KV + MTP3 384K
bash scripts/inference/glm53/switch-glm53-exl3-profile-v6.sh start

# GLM multimodal MTP3 384K rollback
bash scripts/inference/glm53/switch-glm53-exl3-profile-v5.sh start

# GLM DFlash2 98K
bash scripts/inference/glm53/switch-glm53-exl3-profile-v3.sh start

# Qwen TP2 SGLang/DSpark
bash scripts/inference/qwen38/switch-qwen38-backend-v4.sh sglang

# Qwen TP1 vLLM/DFlash2 with BF16 KV on physical GPU0
bash scripts/inference/qwen38/switch-qwen38-backend-v5.sh dflash2-vllm-tp1-bf16kv

# Qwen Flash-Next FP8 TP2 with mandatory PLE host-RAM offload
bash scripts/inference/qwen38/switch-qwen38-flash-next-profile-v1.sh start

# DS4
bash scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
```

Then authenticate and attest the served model:

```bash
bash scripts/run-arm.sh --probe <arm>
```

Health alone is insufficient; the probe requires exactly one served model with
the expected id.

## Repetitions

Run three repetitions per arm. Report:

- mechanical planning completion as counts out of three;
- requirement discovery as per-FR counts out of three; and
- blind rubric quality as a range with the spread shown, never as a falsely
  precise mean.

A 2/3 versus 3/3 split calls for more repetitions, not a winner declaration.

## Grading

### 1. Mechanical planning boundary

`scripts/grade-planning.sh` captures model-authored artifacts from the graph and
fails closed unless the run stopped exactly before implementation. It writes:

- `outcome.planning.json`;
- `changed-files.txt` and `diff.patch`;
- `model-attestation.json`; and
- `discovery-checklist.tsv`.

### 2. Requirement discovery

Complete every row in `discovery-checklist.tsv` against the run's recorded
protocol reference. `grade-planning.sh` resolves v1 for legacy receipts without
a version and requires explicit `protocol_version: "v2"` for v2. Score spec
discovery, plan accounting, and graph accounting independently.

The selected protocol's hidden suite remains an executable encoding of its
reference requirements and an integrity cross-check, but planning runs never
copy or execute it.

### 3. Blind rubric

Score `rubric.md` from anonymised brainstorm, spec, interview, plan, alignment,
and task graph artifacts. The rubric covers only planning. It contains no
implementation, test-result, mutation, or wave-gate dimensions.

Mechanical protocol failures are gates: prose quality cannot rescue a run that
started implementation, used another child model, or was contaminated.

## Blinding

```bash
bash scripts/anonymise.sh batch-1 runs/2026*
```

The script first rejects any batch mixing protocol versions or protocol hashes,
then shuffles arm labels and removes model/backend tells. It writes the shared
protocol identity to `blind/<batch>/protocol.json`. Do not open the mapping
until every score and citation is saved. If the grader watched a live run,
record it as unblinded.

## Voiding and invalidating

**Void and rerun** only for harness failure, backend death, Cortex recall,
missing/mismatched child routing, or operator answer drift.

**Retain as model evidence** context exhaustion, looping, phase timeout, model
give-up, bad requirements, bad architecture, or bad decomposition.

**Mark invalid at the stop boundary** if implementation starts. Preserve the
record because failure to obey the explicit stop condition is process evidence,
but do not mix it into planning-quality comparisons.

## Layout

```text
frozen/, hidden/, rubric.md       immutable retired v1 protocol
protocols/v2/
  source-lock.json                pinned Loom source provenance
  frozen/brief.md                 task and planning-only stop condition
  frozen/ui-relay-types.ts        frozen ADTs/signatures copied to worktree
  frozen/wire-contract.md         explicit current Pi raw-wire authority
  frozen/answer-key.md            scripted operator answers
  hidden/reference-spec.md        v2 FR checklist
  hidden/ui-relay.hidden.test.ts  v2 executable cross-check
  rubric.md                       v2 blind planning rubric
operator-tmux.md                  attended procedure, outside protocol
runs/<run-id>/                    receipts, artifacts, transcript, scores
```

## Running a batch

Before the first run:

```bash
bash scripts/verify-harness.sh
bash scripts/isolation.sh off
bash scripts/isolation.sh status
bash scripts/run-arm.sh --probe glm-fp8
```

If the Loom baseline is stale, refresh and commit it before comparing arms:

```bash
bash scripts/baseline.sh
```

Per run:

```bash
bash scripts/run-arm.sh glm-fp8 1  # v2 by default
```

`run.json` records `protocol_version` and the hash over every selected protocol
artifact. The launcher prints the matching answer-key path; use that path rather
than assuming the retired root `frozen/` directory.

Follow the printed launch instructions. In Pi, submit the one-line `/loom`
command exactly as printed. Answer only from `frozen/answer-key.md`, recording
every exchange in the run’s `interview.md`.

When decomposition completes, stop before Wave 1. Copy the parent Pi transcript
to `session.jsonl`, then run:

```bash
bash scripts/verify-run-models.sh runs/<run-id>
bash scripts/grade-planning.sh <worktree> runs/<run-id>
grep -l CORTEX_MEMORY_START runs/<run-id>/session.jsonl  # any hit voids
```

`grade-planning.sh` copies brainstorm, spec, plan, alignment, and the active task
graph directly from the worktree. `interview.md` and `session.jsonl` must already
be present in the run directory.

After preserving all artifacts:

```bash
git -C ~/dev/claude-plugins/loom worktree remove <worktree>
```

After the batch:

```bash
bash scripts/isolation.sh on
bash scripts/anonymise.sh batch-1 runs/2026*
```

See `operator-tmux.md` for reliable attended operation and transcript capture.

## Outcome record

Keep process outcomes orthogonal:

```json
{
  "run_id": "...",
  "arm": "glm-mtp",
  "protocol_version": "v2",
  "protocol_sha256": "...",
  "wall_clock_s": 0,
  "phases_completed": ["brainstorm", "specify", "architecture", "plan-alignment", "decompose"],
  "context_exhausted": false,
  "looped": false,
  "gave_up": false,
  "implementation_started": false,
  "task_graph_at_execution_boundary": true,
  "child_models_attested": true,
  "cortex_contaminated": false,
  "planning_complete": true,
  "voided": false,
  "voided_reason": null
}
```
