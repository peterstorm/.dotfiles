# Blind planning rubric

Scored from an anonymised planning record (arm-A / arm-B). Do not open the
mapping file until every score below is written and saved.

Score each dimension 0–4. Anchor every score to a quoted line or `file:line`
from the artifact — a score with no citation is a vibe and must be struck.

**0** absent · **1** attempted, wrong · **2** adequate, generic ·
**3** good, specific to this problem · **4** better than the reference answer

Mechanical protocol facts in `outcome.planning.json` are gates, not rubric
scores. A run with implementation started, a non-pending task, Cortex
contamination, or failed child-model attestation is invalid even if its prose
looks good.

## A. Specification (`spec.md`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| A1 | Requirement discovery | Names failure modes the brief never mentioned: partial lines, CRLF, recursive delegation, empty options, out-of-range selections, double answers, and orphaned requests on exit |
| A2 | Requirements are testable | Each FR states observable input, output, error kind, ordering, and retained state; no “handle gracefully” language |
| A3 | Contract fidelity | Distinguishes method-based wire input from decoded `ChildFrame` values and does not contradict the frozen types |
| A4 | Scope discipline | Excludes shell work and limits the eventual implementation to `ui-relay.ts` and one associated test file |
| A5 | Uncertainty handling | Marks genuine ambiguities, asks only load-bearing questions, and records defensible decisions without inventing requirements |

Cross-check A1 against every row in `discovery-checklist.tsv`. The checklist is
evidence for this score, not a substitute for judgement.

## B. Interview (`interview.md`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| B1 | Question value | Asks what cannot be inferred; does not ask what the brief or frozen contract already answers |
| B2 | Question economy | Few questions, each load-bearing; no repeats across phases |
| B3 | Answer integration | “Use your judgement” becomes one explicit, coherent decision in the spec rather than stalling or repeated questioning |

## C. Architecture (`plan.md`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| C1 | Protocol model | Correctly separates streaming line framing, hostile wire parsing, decoded frames, and reducer correlation |
| C2 | Exact transition semantics | Correctly specifies duplicate, mismatch, range, cancellation, done, child-exit, parent-shutdown, progress, and closed-state behavior |
| C3 | Failure discipline | Accounts for malformed JSON, empty lines, explicit CR rejection, recursive methods, unknown methods, invalid ids, and per-line recovery |
| C4 | Functional-core fit | Pure deterministic transformations, immutable state, exhaustive unions, typed errors, no I/O or speculative seams |
| C5 | Decision quality | Important choices include rationale and a genuinely plausible rejected alternative; no ceremonial ADRs for local choices |
| C6 | Verification design | Curated examples and properties prove the identified invariants without relying on mocks or shell integration |
| C7 | Honest sizing | The work is represented at its real size; no public wiring, extra ADR waves, or unrelated follow-up tasks |

## D. Plan alignment (`plan-alignment.md`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| D1 | Independent scrutiny | Finds contradictions and omissions rather than merely confirming that the plan resembles the model’s own spec |
| D2 | Contract cross-check | Checks plan claims directly against the frozen types and requirements source |
| D3 | Actionability | Every reported gap has a precise correction, owner artifact, and verification consequence |

## E. Decomposition (`task-graph.json`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| E1 | Traceability | Every discovered FR/NFR maps to the task that implements or tests it; no invented anchors |
| E2 | Dependency accuracy | Dependencies reflect real code constraints and maximize safe parallelism without splitting inseparable behavior |
| E3 | Task context fidelity | Task descriptions preserve exact protocol semantics instead of compressing away edge cases |
| E4 | Verification policy | Every code task requires appropriate new tests and regression evidence; documentation-only waivers are justified |
| E5 | Scope and sizing | File lists stay within the allowed implementation surface and avoid ceremonial waves or unrelated ADR tasks |

## F. Process

| # | Dimension | What a 4 looks like |
|---|---|---|
| F1 | Stop-boundary compliance | Graph is execution-ready with all tasks pending and no implementation/review/gate child launched |
| F2 | Recovery | Recovers from phase timeouts or failed artifact production without losing decisions, looping, or changing operator answers |
| F3 | Artifact consistency | Brainstorm, spec, plan, alignment, and graph agree on terms, scope, and semantics |

## Scoring output

Per run, save:

1. the completed dimension table with citations;
2. the completed `discovery-checklist.tsv`;
3. **one sentence on the decisive difference** — or “no material difference”;
4. the strongest artifact, quoted; and
5. the worst defect, quoted, with the FRs and downstream tasks it would affect.

Do not speculate about implementation quality. This benchmark measures whether
the model produced an implementation-ready plan, not whether unseen code would
have worked.
