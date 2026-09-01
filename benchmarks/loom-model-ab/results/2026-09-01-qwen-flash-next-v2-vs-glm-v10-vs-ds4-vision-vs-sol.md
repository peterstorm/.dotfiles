# Qwen Flash-Next v2 versus GLM v10 versus DS4 Vision versus Sol — UI-relay v2

Date: 2026-09-01

## Scope

One mechanically valid, unblinded protocol-v2 planning run per model:

- Qwen Flash-Next v2: `20260901T085735Z-qwen-flash-next-v2-1`;
- DS4 Vision r21: `20260901T071856Z-ds4-vision-r21-1`;
- GLM v10: `20260831T122019Z-glm-v10-dcp2-1`;
- GPT-5.6 Sol: `20260831T143720Z-sol-1`.

All used protocol hash `f8d3a66edae61265db15492d5508f1d3e6ac216d59b23519a8c5aff5daa1ce99`, exact child routing, no Cortex recall, and the same stop-before-Wave-1 contract. One run per model is descriptive only.

## Score comparison

| Group | Qwen v2 | DS4 Vision | GLM v10 | Sol |
|---|---:|---:|---:|---:|
| Specification | 15/20 | 14/20 | 15/20 | 16/20 |
| Interview | 2/12 | 5/12 | 6/12 | 6/12 |
| Architecture | 21/28 | 21/28 | 22/28 | 24/28 |
| Plan alignment | **9/12** | 8/12 | 5/12 | 4/12 |
| Decomposition | 9/20 | 12/20 | 12/20 | **18/20** |
| Process | 7/12 | 9/12 | 9/12 | 10/12 |
| **Total** | **63/104** | **69/104** | **69/104** | **78/104** |

## Hidden requirement discovery

| Discovery | Qwen v2 | DS4 Vision | GLM v10 | Sol |
|---|---:|---:|---:|---:|
| Full | **23/26** | 18/26 | **23/26** | 22/26 |
| Partial | 3/26 | 8/26 | 3/26 | 4/26 |
| Missed | 0/26 | 0/26 | 0/26 | 0/26 |

Qwen therefore tied GLM for strongest protocol discovery. Its lower total is not a protocol-comprehension result; it is primarily an orchestration-economy and decomposition result.

## What Qwen did well

- Matched GLM's 23 fully discovered hidden requirements.
- Correctly handled any-pending-id correlation, stale ids, cancellation, exact response shapes, generic events, abort, and settled no-op.
- Produced strong byte-framing reasoning, including LF-before-decode, split UTF-8 preservation, strict decoding, byte caps, and per-record recovery.
- Its alignment passes found real plan contradictions rather than merely confirming self-consistency.
- All ten children stayed on the exact local Qwen v2 selector despite agent frontmatter naming cloud defaults.

## Why it scored lower

### Interview explosion

Qwen asked 71 logged questions and repeatedly revisited test path, purity, dependencies, scope, NFR priority, error handling, observability, fuzz tooling, and architecture shape. Many answers were fixed by the visible authority. This consumed nearly two hours and 57.1% of the 262K parent context.

### Invented operator authority

The operator repeatedly supplied the frozen two-file definition of done. The final plan nevertheless states that the operator permitted four ADR files. That ruling does not exist in `interview.md`.

### Oversized graph

The two-file core became eight tasks across four waves:

- T1 implementation;
- T2 and T3 serial edits to one test file;
- T4–T7 ADR files outside scope;
- T8 an empty-file gate task.

T1 also requires a `new-tests` proof while explicitly forbidding changes to the test file. Sol's one atomic source/test task remains the benchmark's best decomposition.

### Terminal table remained wrong

Like earlier arms, Qwen observed `agent_settled`. It also omitted `terminate-child` on early child exit and made the exit error conditional on pending dialogs. Three alignment passes did not re-derive those transitions from frozen authority.

## Operational interpretation

The Qwen v2 runtime itself was stable: immutable image verification, deterministic greedy probes, exact model routing, zero restarts, and the two-hour benchmark workload all passed. The benchmark result instead confirms the earlier promotion decision: runtime/state safety does not compensate for semantic and instruction-following weaknesses.

## Bottom line

- **Sol** remains the strongest benchmark-shaped planner.
- **GLM** and **Qwen** tie for best hidden requirement discovery.
- **DS4 Vision** has stronger process economy than Qwen and better vision specialization.
- **Qwen v2** is technically stable but currently the weakest default Loom choice because it turns good protocol reasoning into an over-questioned, internally contradictory delivery graph.
