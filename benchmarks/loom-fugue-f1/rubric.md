# Blind planning rubric — Fugue F1 map suite v1

Grade only anonymised runs with the same suite ID and protocol SHA. This total
is not comparable with the UI-relay benchmark.

Score every dimension 0–4 and cite an artifact line: **0** absent · **1**
attempted but wrong · **2** generic/partial · **3** good and Fugue-specific ·
**4** unusually complete and internally coherent.

Mechanical facts in `outcome.planning.json` are gates, not points. The maximum
is 104 points.

## A. Specification (`spec.md`) — 20

| # | Dimension | What a 4 looks like |
|---|---|---|
| A1 | Requirement discovery | Covers typing, preflight bounds, ordering, retries, cancellation, durable identity, all adapters, freshness, routing, authoring, visualization, and observability |
| A2 | Observable contracts | Requirements state inputs, outcomes, error modes, ordering, and retained state without vague “handle gracefully” language |
| A3 | Fugue fidelity | Preserves static acyclic topology, pure transitions, typed errors, capability discipline, spend authority, and canonical compatibility |
| A4 | Scope | Includes every necessary cross-cutting seam while excluding subgraphs, loops, agents, quorum, dynamic code, and unrelated host work |
| A5 | Uncertainty | Separates accepted ADR/CONTEXT authority from research, identifies real unknowns, and does not ask the user to rediscover repository facts |

## B. Interview (`interview.md`) — 12

| # | Dimension | What a 4 looks like |
|---|---|---|
| B1 | Question value | Asks only product or trade-off questions not fixed by the brief, answer key, accepted ADRs, or code |
| B2 | Question economy | Few load-bearing questions with no repetition or file-location trivia |
| B3 | Answer integration | Every answer becomes one explicit decision propagated consistently through later artifacts |

## C. Architecture (`plan.md`) — 28

| # | Dimension | What a 4 looks like |
|---|---|---|
| C1 | Domain and type model | Cleanly separates Map Node, Map Instance, worker contract, instance address, gathered output, limits, and typed terminal states |
| C2 | Scheduling and bounds | Preflight cardinality, bounded admission, deterministic indexed gather, cancellation, retry exhaustion, and empty input are exact |
| C3 | Durability and resume | Discovers adapter divergence, defines composite identity/input agreement/attempt semantics, and prevents successful effect replay |
| C4 | Capabilities, spend, freshness | Reuses existing authorities and carries instance identity through capability, freshness, and effect witnesses without unsafe casts |
| C5 | Static graph integration | Routing, fingerprinting, authored field references, codegen, describe, exports, and plate visualization remain static and coherent |
| C6 | Functional-core fit | Pure immutable transitions and deep domain modules hold policy; I/O shells and adapters remain thin; expected failures are typed |
| C7 | Verification | Curated scenarios plus fast-check properties cover order, bounds, adapter parity, crash points, cancellation, drift, and determinism without mocks |

## D. Plan alignment (`plan-alignment.md`) — 12

| # | Dimension | What a 4 looks like |
|---|---|---|
| D1 | Independent scrutiny | Finds substantive contradictions or omissions rather than merely restating the plan |
| D2 | Authority cross-check | Checks brief, CONTEXT, accepted ADRs, current code, and adapter behavior while treating spikes as non-normative |
| D3 | Actionability | Every gap has a precise artifact correction and verification consequence |

## E. Decomposition (`task-graph.json`) — 20

| # | Dimension | What a 4 looks like |
|---|---|---|
| E1 | Traceability | Every FR and acceptance scenario maps to implementation and test context with real repository anchors |
| E2 | Dependency accuracy | Types and identity precede scheduler/adapters; authoring and observability parallelize where safe; integration follows prerequisites |
| E3 | Context fidelity | Task context preserves ordering, preflight, retry, resume, adapter, freshness, and static-topology invariants |
| E4 | Verification policy | Every behavior task owns focused examples/properties and final full-suite/Redis evidence; no test waivers |
| E5 | Scope and sizing | Tasks are implementation-sized, include docs/exports, avoid mega-tasks and ceremonial work, and start no Wave 1 work |

## F. Process — 12

| # | Dimension | What a 4 looks like |
|---|---|---|
| F1 | Stop-boundary compliance | Graph is execution-ready with every task pending and no forbidden child or production edit |
| F2 | Recovery | Recovers from phase faults without steering, answer drift, loops, or lost decisions |
| F3 | Artifact consistency | Brainstorm, spec, architecture, alignment, and graph use one vocabulary and agree on all product decisions |

## Required grader output

Save the completed dimensions with citations, the completed discovery checklist,
one decisive-difference sentence, the strongest quote, and the worst quoted
defect with affected FRs/tasks. Do not speculate about implementation that was
not performed.
