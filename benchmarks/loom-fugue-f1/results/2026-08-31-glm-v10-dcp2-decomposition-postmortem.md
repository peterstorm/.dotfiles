# GLM v10 Fugue F1 planning postmortem

- Date: 2026-08-31
- Run: `20260831T143252Z-glm-v10-dcp2-1`
- Result: **VOID — mechanical admission failed**

## Correction: GLM did produce a plan

GLM completed brainstorm, specification, and architecture. It selected the recommended node-owned map with additive runtime threading and produced a 69,118-byte architecture plan. Initial plan alignment found one real omission—FR-004 freshness/effect identity—and routed back to architecture. After one incomplete revision attempt, GLM revised the plan with the missing worker side-effect profile and per-item witness identity. The second alignment pass reported no gaps.

The dominant failure occurred in **decomposition**, not architecture planning.

## What happened

1. The completed plan was 69 KiB, larger than the read tool's 50 KiB single-response limit.
2. The first decompose children spent their output budget reading the plan in chunks and reasoning about it. GLM's hidden thinking and visible answer shared a 32,768-token output ceiling.
3. Two decompose children returned empty results. Later attempts reached `stopReason: length` after consuming most of the ceiling in thinking and emitted either no JSON or truncated JSON.
4. The parent shortened the prompt and inlined the essential requirement/decision material. This eventually yielded a complete candidate graph.
5. The task-graph validator rejected that graph with 15 trace-ownership errors: several contributions had no completion claim, two tasks lacked anchors, and some completion claims appeared before their contributing task.
6. A corrective decompose retry hallucinated a materially different graph with wrong agent names, wrong verification-policy shape, wrong paths, and fabricated decision titles. It was discarded.
7. The parent retained the earlier structurally valid graph and mechanically repaired the validator-reported trace bookkeeping. The final artifact contained 20 pending tasks across four waves and reached execute/Wave 1 without starting implementation.

The final graph therefore existed, but it was not a clean, uninterrupted, model-authored decomposition. Parent intervention was substantial enough that the run could not be admitted as normal model evidence.

## Causal attribution

### Model behavior

- **Over-elaboration:** a 69 KiB architecture plan was disproportionate even for the broader F1 feature and created downstream context/output pressure.
- **Poor output-budget allocation:** decompose attempts used most of the shared output ceiling for reasoning before emitting the required machine-readable artifact.
- **Weak trace ownership:** the first complete graph had 15 mechanical trace/completion defects.
- **Unstable correction:** the validator-directed retry replaced rather than repaired the graph and hallucinated incompatible project details.
- **Repeated planning-style pattern:** as in UI-relay, GLM preferred many decisions/tasks and substantial ceremony. In F1 that tendency grew into 20 tasks and four waves.

### Loom/orchestration behavior

- The decompose agent had to consume a large plan through a 50 KiB read surface while returning a large JSON object under a 32,768-token shared thinking/text ceiling.
- Empty or length-truncated child completion still advanced orchestration from `decompose` to `execute`, forcing manual phase resets.
- The parent lacked a clean structured channel for retrieving partial child output, encouraging transcript extraction and prompt-inlining recovery.
- The trace validator reported useful deterministic errors, but correction required another unconstrained generative pass rather than a narrow repair operation.

These are real harness pressure multipliers. They do not erase the model's verbosity or malformed graph, but they explain why a usable architecture failed to become a clean benchmark artifact.

### Benchmark invalidation, separate from planning quality

Even after reaching the boundary, three fail-closed protocol violations independently voided the run:

1. During diagnosis the parent read host-global Pi settings, exposing an Obsidian package path in the transcript. The isolated process did not load Obsidian, but transcript occurrence is sufficient for contamination.
2. Recovery attempted diagnostic writes under `/tmp`, outside the `.claude/`-only write scope.
3. Five failed/retried children lacked acceptable final textual output. Later successful retries cannot erase those records.

These violations explain the **VOID** result. They are not evidence that GLM could not understand the feature.

## Interpretation

The run demonstrates three different facts:

1. **Feature architecture:** GLM could investigate the Fugue codebase, specify the map/fan-out feature, select a credible architecture, and repair a genuine alignment omission.
2. **Decomposition reliability:** GLM could not independently turn its oversized plan into a schema-valid graph within the available output budget. This is the material model/orchestration failure.
3. **Benchmark admission:** recovery contaminated the transcript and crossed the side-effect boundary, so no semantic score can be reported regardless of the final graph.

The accurate summary is therefore:

> GLM produced a substantial architecture plan, but its verbosity and unstable machine-readable decomposition interacted badly with Loom's read/output limits. Recovery eventually produced a valid boundary artifact, but only after parent repair and protocol-invalid side effects.

## Potential harness experiments

Any future run should remain a fresh protocol repetition rather than retroactively changing this result. Useful non-answer-leaking experiments would include:

- cap architecture artifact size or require a concise decomposition handoff section;
- give decompose a structured artifact channel separate from visible reasoning;
- reserve output tokens for final JSON;
- prevent failed child stops from advancing the phase;
- add deterministic repair for trace-ownership bookkeeping;
- reject out-of-scope paths and unknown agent names before accepting a replacement graph.

No second repetition was started for this batch.
