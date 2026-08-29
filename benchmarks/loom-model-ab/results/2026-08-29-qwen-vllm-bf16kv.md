# Qwen3.8-27B vLLM TP1/BF16-KV planning batch — 2026-08-29

## Identity

- Arm: `qwen-vllm-bf16kv`
- Pi selector: `desktop-vllm/qwen3.8-27b:xhigh`
- Served model: `qwen3.8-27b`
- Runtime container: `qwen38-27b-bf16-dflash2-vllm-v3`
- Context: 262,144
- Loom baseline: `3815f65bfab4351f49f0e21e7b7415cdab1fda86`
- Protocol: retired `v1`
- Protocol SHA-256: `17908b755b8a9a7a1fda554c62fcb2a6379a1bb8dd606333ec74154be2756dd3`

> **Historical-score caveat:** v1's visible brief named the shipped Pi RPC
> envelope while its hidden reference expected a synthetic direct-method wire.
> Preserve these scores for v1 reproducibility only; new v2 scores are not
> numerically comparable.

Cortex remained disabled for the whole batch. Every executed child attested to
the exact parent selector. No implementation, test, reviewer, ADR-writer, or
wave-gate child ran.

## Mechanical outcomes

| Repetition | Outcome | Planning complete | Notes |
|---|---|---:|---|
| 1 | Valid terminal boundary | Yes | 10 tasks pending at execute/wave 1; five children attested; GitHub issue #34 |
| 2 | Retained orchestration loop | No | Brainstorm + 25-question specification interview, then restarted `/loom` without writing the spec |
| 3 | Retained specification timeout | No | Brainstorm + prolonged specification interview; no spec before the phase budget expired |

Batch completion: **1/3**. The 2/3 incompletions are model process evidence, not
voided runs: the backend stayed healthy, routing matched, Cortex was absent, and
the harness did not fail.

Repetition 1 initially exposed a grader compatibility defect: the validated task
graph used an absolute in-worktree `spec_file`, while the grader only joined
relative paths. The model-authored worktree was reconstructed from its preserved
commit, and the unchanged artifacts passed after the grader normalized both path
forms before enforcing worktree containment.

## Blind semantic result

Only repetition 1 passed the mechanical gate and was eligible for semantic
scoring. Two fresh independent blind graders scored it:

- **47/104**
- **45/104**

Reportable range: **45–47/104**. No mean is reported from one valid repetition.

Canonical discovery across 25 hidden requirements:

| Artifact | YES | PARTIAL | NO |
|---|---:|---:|---:|
| Specification | 20 | 2 | 3 |
| Plan | 20 | 2 | 3 |
| Task graph | 20 | 2 | 3 |

## Semantic findings

Strongest finding: the plan correctly identified that `JSON.parse` accepts a
trailing carriage return as JSON whitespace and required explicit pre-parse CR
rejection.

Original v1 grading findings:

1. It treated decoded `ChildFrame` tags as the hostile method-based wire
   envelope.
2. It declared recursive delegation unreachable instead of mapping v1's hidden
   reserved methods to `recursive-delegation`.
3. It accepted empty select option arrays.
4. It made `done` a no-op instead of cancelling pending requests, closing the
   relay, and emitting `close-child`.
5. It expanded a small core into linter wiring, three test files, and eight
   ceremonial ADR tasks.
6. Plan alignment reported no gaps and therefore failed to correct any of the
   contract defects.

## Interpretation

This retired-v1 batch does not support a current-contract winner claim. Qwen
produced one detailed but over-engineered plan, then failed to complete two
repetitions. The wire and recursive-delegation findings above partly reflect
v1's stale hidden contract rather than current Loom. A fresh v2 batch is
required before comparing implementation readiness; the 1/3 process completion
fact remains valid historical evidence.

Serving performance is recorded separately in
`benchmarks/vllm-tps/2026-08-29-qwen-vllm-tp1-bf16kv.md`; it must not be mixed
with planning quality.
