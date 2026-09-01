# DS4 Vision r21 versus GLM v10 versus GPT-5.6 Sol — UI-relay v2

Date: 2026-09-01

## Scope

This compares one mechanically valid, unblinded protocol-v2 planning run per model:

- DS4 Vision r21: `20260901T071856Z-ds4-vision-r21-1`;
- GLM v10: `20260831T122019Z-glm-v10-dcp2-1`;
- GPT-5.6 Sol: `20260831T143720Z-sol-1`.

All used the same frozen protocol hash and stopped before Wave 1 with exact child routing, no Cortex contamination, and no implementation. GLM used an earlier Loom base; its exposed harness defects were excluded from model scoring. One repetition per model is descriptive only.

## Score comparison

| Group | DS4 Vision r21 | GLM v10 | Sol |
|---|---:|---:|---:|
| Specification | 14/20 | 15/20 | 16/20 |
| Interview | 5/12 | 6/12 | 6/12 |
| Architecture | 21/28 | 22/28 | 24/28 |
| Plan alignment | **8/12** | 5/12 | 4/12 |
| Decomposition | 12/20 | 12/20 | **18/20** |
| Process | 9/12 | 9/12 | 10/12 |
| **Total** | **69/104** | **69/104** | **78/104** |

## Hidden requirement discovery

| Discovery | DS4 Vision r21 | GLM v10 | Sol |
|---|---:|---:|---:|
| Full | 18/26 | **23/26** | 22/26 |
| Partial | 8/26 | 3/26 | 4/26 |
| Missed | 0/26 | 0/26 | 0/26 |

The equal DS4/GLM total masks different behavior. GLM discovered substantially more of the exact protocol. DS4 recovered more effectively during alignment but used that scrutiny on cap placement and answer-shape details while missing broader correlation and terminal contradictions.

## What DS4 did best

DS4 was the only run whose alignment phase found a substantive architecture defect and forced a corrected plan. The corrected decoder design distinguishes:

- complete per-record limits;
- unterminated-tail limits;
- aggregate chunks containing multiple legal records;
- cross-chunk oversized-record resynchronization;
- exactly-one-error ordering.

That earned 8/12 for alignment, versus 5 for GLM and 4 for Sol.

## Where DS4 lost ground

DS4 asked 34 operator questions, many of them answered directly by the visible frozen authority. It then introduced additional policy:

- strict queue-head-only answer resolution;
- a separate error for seen-but-not-pending ids;
- exact-key rejection for typed answers;
- settlement observation;
- hand-rolled UTF-8 validation;
- stable message prose as a tested contract.

The first, second, and settlement choices contradict v2. The latter choices added implementation and interview complexity without increasing hidden requirement coverage.

Its decomposition also repeated GLM's main planning-shape defect: three serial two-file code tasks followed by six ADR-writing tasks. Sol's single atomic source/test task explains most of its score lead.

## Terminal-semantics pattern

All three models independently mishandled terminal transitions:

- GLM: retained or failed to clear pending on settlement, exit, and abort;
- Sol: additionally observed settlement and omitted early-exit termination;
- DS4: repeated Sol's terminal behavior and also introduced wrong pending-id lookup rules.

None reconstructed the reducer directly from the frozen transition authority before accepting its own local policy. This is the dominant cross-model failure mode in this benchmark.

## Bottom line

- **Sol** remained the best benchmark-shaped planner through economy and decomposition.
- **GLM** remained the strongest exact requirement discoverer.
- **DS4 Vision** demonstrated the best independent alignment recovery and decoder analysis, but over-questioning and invented reducer policy prevented that strength from improving the final score.

The defensible conclusion from one run each is not a model ranking. It is that orchestration discipline dominates the score: frozen facts must bypass interviews, reducer transitions need an explicit authority-derived table, and a two-file core should default to one implementation task with no ADR wave.
