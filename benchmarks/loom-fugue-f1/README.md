# Loom planning benchmark: Fugue F1 runtime-width fan-out

This benchmark measures implementation-ready planning for an unimplemented
Fugue feature. It is a separate benchmark family from `loom-model-ab`; scores
must never be compared across those tasks.

## Immutable identities

- Suite: `fugue-f1-map-v1`
- Target: Fugue `274cadbdbf0438ae5c43e7ca225e27b7724f7e3d`
- Loom runtime: `3815f65bfab4351f49f0e21e7b7415cdab1fda86`
- Pi: `0.83.0`
- Protocol SHA: `d2629e9eb966e25364e24a34423e55247040344115874dc2f2de5fee415beed1`

`source-lock.json` pins the target, runtime, and model-visible repository
sources. The protocol SHA covers the source lock, brief, answer key, hidden
reference, hidden scenarios, and rubric.

## What the model sees

The model receives only `frozen/brief.md` through a neutral `/tmp` path plus the
pinned Fugue checkout. Accepted ADRs and `CONTEXT.md` are normative. Existing
research spikes are visible brownfield context but are not the answer key.

The model must stop after decomposition with all Wave 1 tasks pending. It must
not implement, create issues, push, update production documentation, or read
benchmark/vault artifacts.

## Prepare

```bash
# The target checkout may be anywhere; these are defaults.
export FUGUE_REPO="$HOME/dev/agentic/fugue"
export LOOM_RUNTIME_REPO="$HOME/dev/claude-plugins/loom-benchmark-runtime-3815f65"

bash benchmarks/loom-fugue-f1/scripts/isolation.sh off
bash benchmarks/loom-fugue-f1/scripts/baseline.sh
bash benchmarks/loom-fugue-f1/scripts/verify-harness.sh
```

Isolation removes both Cortex and Obsidian packages, replaces the live Loom
package registration with the pinned detached runtime, and keeps one exact Pi
settings backup. Start a fresh Pi process after activation. Restore only after
the entire matched batch:

```bash
bash benchmarks/loom-fugue-f1/scripts/isolation.sh on
```

## Prepare an arm

```bash
bash benchmarks/loom-fugue-f1/scripts/run-arm.sh --list
bash benchmarks/loom-fugue-f1/scripts/run-arm.sh --probe glm-v8
bash benchmarks/loom-fugue-f1/scripts/run-arm.sh glm-v8 1
```

The final command creates a detached target worktree and prints one RPC-driver
command. The driver uses strict JSONL framing, supervises extension UI prompts,
logs every answer, watches the TaskGraph, and aborts automatically at the
planning boundary. It does not infer answers: the operator must use the frozen
answer key exactly.

## Grade

```bash
bash benchmarks/loom-fugue-f1/scripts/grade-planning.sh \
  /path/to/fugue-bench-worktree \
  benchmarks/loom-fugue-f1/runs/<run-id>
```

Mechanical grading fails closed on suite/protocol/source identity, stale target
or runtime, wrong-task artifacts, production changes, implementation children,
empty child completions, model mismatch, Cortex/Obsidian/vault/hidden-reference
contamination, external side effects, and any state other than the pending Wave
1 boundary.

Semantic grading uses `rubric.md`, `hidden/reference-spec.md`, and
`hidden/acceptance-scenarios.md`. Grade anonymised runs from one suite and
protocol SHA only.

## Blind batch

```bash
bash benchmarks/loom-fugue-f1/scripts/anonymise.sh batch-id \
  benchmarks/loom-fugue-f1/runs/<run-1> \
  benchmarks/loom-fugue-f1/runs/<run-2> \
  benchmarks/loom-fugue-f1/runs/<run-3>
```

Run three repetitions per arm. Report completion rate, discovery coverage,
independent 104-point grader ranges, questions, wall time, and cumulative
tokens. Runtime throughput remains a separate result surface.

## Benchmark admission

A protocol change is admissible only when:

1. source locks verify against Git objects;
2. reference FRs and acceptance-scenario tags are exactly equal;
3. the pinned Fugue typecheck and framework suite are green;
4. valid synthetic planning evidence passes mechanical grading;
5. implementation, contamination, empty-child, and mixed-batch mutants fail;
6. shell checks, RPC-driver tests, and `git diff --check` pass.
