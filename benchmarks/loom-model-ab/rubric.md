# Blind rubric

Scored from an anonymised run record (arm-A / arm-B). Do not open the mapping
file until every score below is written and saved.

Score each dimension 0–4. Anchor every score to a quoted line or a file:line
from the artifact — a score with no citation is a vibe and must be struck.

**0** absent · **1** attempted, wrong · **2** adequate, generic ·
**3** good, specific to this problem · **4** better than the reference answer

## A. Spec phase (`spec.md`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| A1 | Requirement discovery | Names failure modes the brief never mentioned — partial lines across chunks, CRLF, double-answer, orphaned pending requests on child exit |
| A2 | Requirements are testable | Each FR states an observable outcome; no "should handle X gracefully" |
| A3 | Scope discipline | Explicitly excludes the shell, timers, spawning; does not drift into building them |
| A4 | Uncertainty handling | Genuine ambiguities marked rather than silently decided; nothing invented that contradicts the answer key |

Cross-check A1 against the FR discovery column in `hidden/reference-spec.md`.
That column is evidence for this score, not a substitute for it.

## B. Interview quality (`interview.md`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| B1 | Question value | Asks what it cannot infer; does not ask what the brief already answers |
| B2 | Question economy | Few questions, each load-bearing; no repeats across phases |
| B3 | Response to "use your judgement" | Makes a defensible call and records it in the spec, rather than stalling or asking again |

## C. Architecture phase (`plan.md`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| C1 | Fit to the frozen contract | Design follows from the given types; no reinvention, no proposed edits to the frozen file |
| C2 | Illegal states unrepresentable | Uses the discriminated unions and branding rather than re-validating downstream |
| C3 | Decision quality | States the reasoning and the rejected alternative; the CRLF, empty-line, and duplicate-response rules are decided here, not discovered mid-implementation |
| C4 | Honest sizing | Task breakdown matches the actual work; no ceremonial waves for a two-function module |

## D. Implementation (`ui-relay.ts`)

| # | Dimension | What a 4 looks like |
|---|---|---|
| D1 | Purity | No I/O, no clock, no `node:*`; reducer provably total |
| D2 | Error discipline | Typed values throughout; no throw on child-caused failure; no `any` |
| D3 | Readability | Reads like the surrounding `engine/src/core`; no defensive sprawl |
| D4 | No silent failure | Every swallowed case is either impossible by type or returns a named error |

## E. Tests (the arm's own suite)

| # | Dimension | What a 4 looks like |
|---|---|---|
| E1 | Branch coverage of its own spec | Every FR it wrote has a test |
| E2 | Test quality | Asserts behaviour, not implementation; failure messages identify the requirement |
| E3 | Adversarial cases | Tests hostile input it was never told about |

E2 is corroborated by the mutation score. A high E2 with a low mutation score
means the tests read well and prove little — trust the mutation score and lower
E2 accordingly.

## F. Process

| # | Dimension | What a 4 looks like |
|---|---|---|
| F1 | Gate honesty | Claims of "tests pass" are backed by a recorded run, not asserted |
| F2 | Recovery | Recovers from its own compile/test failures without looping |
| F3 | Scope respect | Touched only the two permitted files; frozen file byte-identical |

## Scoring output

Per run, record the table plus:

- **One sentence on the decisive difference.** If there is none, say so — "no
  material difference on this run" is a legitimate and useful finding.
- **The strongest single artifact** produced by the arm, quoted.
- **The worst defect**, quoted, and whether the hidden suite caught it. A defect
  the hidden suite missed is a gap in the suite; add a test before the next
  batch and note that the suites are no longer identical across batches.
