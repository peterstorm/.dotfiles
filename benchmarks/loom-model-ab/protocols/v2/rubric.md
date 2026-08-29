# Blind planning rubric — protocol v2

Grade only anonymised v2 runs together. Never compare this total directly with
v1: the task contract and discovery surface changed.

Score each dimension 0–4 and cite an artifact line. **0** absent · **1**
attempted, wrong · **2** adequate, generic · **3** good and problem-specific ·
**4** better than the v2 reference.

Mechanical facts in `outcome.planning.json` are gates, not points.

## A. Specification (`spec.md`) — 20

| # | Dimension | What a 4 looks like |
|---|---|---|
| A1 | Requirement discovery | Covers byte chunking, CRLF tolerance, U+2028/U+2029, byte caps, unterminated carry, all nine UI methods, generic events, duplicate-ever ids, response shape, and settlement races |
| A2 | Testability | Every requirement states input, output/error, ordering, and retained state without “handle gracefully” language |
| A3 | Current contract fidelity | Keeps raw `extension_ui_request`/`extension_ui_response`, parsed request ADTs, generic Pi events, and reducer effects distinct; does not revive v1 direct-method or recursive-wire rules |
| A4 | Scope | Limits eventual edits to `ui-relay.ts` and `ui-relay.test.ts`; excludes process, stdio, TUI, timers, extensions, and allowlists |
| A5 | Uncertainty | Treats frozen schema/types as authority, identifies only genuine gaps, and records defensible local decisions without adding policy |

## B. Interview (`interview.md`) — 12

| # | Dimension | What a 4 looks like |
|---|---|---|
| B1 | Question value | Asks only matters not fixed by the brief, wire contract, types, or repository conventions |
| B2 | Question economy | Few load-bearing questions and no repetition across phases |
| B3 | Answer integration | Every judgement answer becomes one explicit coherent decision rather than another question |

## C. Architecture (`plan.md`) — 28

| # | Dimension | What a 4 looks like |
|---|---|---|
| C1 | Protocol model | Separates byte framing, UTF-8/JSON parsing, raw Pi envelopes, parsed ADTs, correlation state, and shell effects |
| C2 | Exact transitions | Correctly handles dialog/fire-and-forget split, duplicate-ever ids, method/value mismatch, exact responses, generic events, settlement, exit, abort, and settled no-op |
| C3 | Failure discipline | Handles byte caps, unterminated carry, malformed records, unsupported UI methods, field/default tables, pending-at-settlement, and per-record recovery |
| C4 | Functional-core fit | Pure deterministic transforms, immutable state, exhaustive unions, typed errors, no I/O or speculative ports |
| C5 | Decision quality | Important choices have rationale and plausible rejected alternatives; no ceremonial ADRs |
| C6 | Verification | Curated examples and properties cover framing, method matrix, response correlation, immutability, and determinism without mocks |
| C7 | Honest sizing | Represents two focused files at their real size with no public wiring or unrelated work |

## D. Plan alignment (`plan-alignment.md`) — 12

| # | Dimension | What a 4 looks like |
|---|---|---|
| D1 | Independent scrutiny | Finds real contradictions or omissions instead of merely confirming self-consistency |
| D2 | Authority cross-check | Checks the plan directly against both frozen v2 files and distinguishes context docs from normative inputs |
| D3 | Actionability | Every gap has a precise artifact correction and verification consequence |

## E. Decomposition (`task-graph.json`) — 20

| # | Dimension | What a 4 looks like |
|---|---|---|
| E1 | Traceability | Every discovered FR/NFR maps to implementation and test context without invented anchors |
| E2 | Dependency accuracy | Dependencies reflect inseparable type/implementation/test constraints while maximizing safe parallelism |
| E3 | Context fidelity | Task context preserves exact envelope names, method fields/defaults, correlation invariants, and terminal ordering |
| E4 | Verification policy | Every code task requires focused tests and regression evidence; no waived executable behavior |
| E5 | Scope and sizing | File lists contain only the two allowed files and avoid ceremonial waves |

## F. Process — 12

| # | Dimension | What a 4 looks like |
|---|---|---|
| F1 | Stop-boundary compliance | Graph is execution-ready with every task pending and no execution child launched |
| F2 | Recovery | Recovers from phase faults without losing decisions, looping, or changing operator answers |
| F3 | Artifact consistency | Brainstorm, spec, plan, alignment, and graph agree on v2 terms, scope, and semantics |

## Required output

Save the completed dimensions with citations, completed v2 discovery checklist,
one decisive-difference sentence, the strongest quote, and the worst quoted
defect with affected FRs/tasks. Do not speculate about unseen implementation.
