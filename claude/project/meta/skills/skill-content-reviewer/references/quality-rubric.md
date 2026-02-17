# Quality Scoring Rubric

Score each dimension 1-5. Be honest — inflated scores don't help the skill author improve.

---

## Description Quality

| Score | Criteria |
|-------|----------|
| 5 | Describes WHAT + WHEN + trigger phrases. Specific enough to avoid over-triggering, broad enough to catch paraphrases. Mentions relevant file types/domains if applicable. Follows project convention. |
| 4 | Has WHAT + WHEN + triggers but slightly vague in one area. Might occasionally over/under-trigger. |
| 3 | Missing either triggers OR clear WHEN conditions. Works but requires users to know the skill exists. |
| 2 | Only describes WHAT with no triggering context. "Creates documents" with no specifics. |
| 1 | Too vague to be useful. "Helps with things." Or too technical with no user-facing language. |

## Instruction Clarity

| Score | Criteria |
|-------|----------|
| 5 | Step-by-step, actionable, specific. Critical info at top. Concrete examples with inputs/outputs. Error handling included. References linked with context. Imperative form. |
| 4 | Clear steps and good structure but missing examples OR error handling. |
| 3 | Has steps but some are vague ("validate the input"). Missing concrete examples. |
| 2 | Mostly prose paragraphs. Instructions require interpretation. No examples. |
| 1 | Ambiguous wall of text. Reader must guess what to do. |

## Progressive Disclosure

| Score | Criteria |
|-------|----------|
| 5 | SKILL.md is lean core instructions. References handle detail. Each reference focused on one topic. Files linked with clear "when to consult" context. Token-conscious structure. |
| 4 | Good split between SKILL.md and references but could be tighter. One or two sections that could move to references. |
| 3 | All content in SKILL.md but under 500 lines. No references needed yet but approaching limit. |
| 2 | SKILL.md is bloated (>500 lines) with no references. Detail that should be split out. |
| 1 | Massive monolithic SKILL.md. Redundant content. No concept of progressive loading. |

## Degrees of Freedom

| Score | Criteria |
|-------|----------|
| 5 | Freedom calibrated per task: text guidance where flexible, pseudocode where patterns exist, exact scripts where fragile. Clear about what's mandatory vs. suggested. |
| 4 | Generally appropriate freedom levels but one area over/under-constrained. |
| 3 | Uniform freedom level throughout — either too prescriptive for creative tasks or too loose for critical operations. |
| 2 | Mismatched freedom — fragile operations left to interpretation, or creative tasks over-specified. |
| 1 | No calibration. Either a wall of "you must" rules for everything, or completely open-ended with no guardrails. |

## Token Efficiency

| Score | Criteria |
|-------|----------|
| 5 | Only includes what Claude doesn't know. Concise examples. Scripts for deterministic ops. Mutually exclusive contexts separated. Estimated <5000 tokens for SKILL.md body. |
| 4 | Mostly efficient with minor redundancy. One or two sections could be trimmed. |
| 3 | Some content Claude already knows (general programming concepts, well-known patterns). Verbose in places. |
| 2 | Significant redundancy. Re-explains common knowledge. Long prose where examples would suffice. |
| 1 | Treats SKILL.md like a tutorial. Explains basics at length. Massive token footprint for limited unique value. |

## Completeness

| Score | Criteria |
|-------|----------|
| 5 | Covers all primary use cases. Edge cases addressed. Has constraints section. Has examples. Handles failure modes. Security considerations if relevant. |
| 4 | Primary use cases covered well. Minor gaps in edge cases or error handling. |
| 3 | Main happy path covered. Missing edge cases, error handling, or examples. |
| 2 | Partially covers the stated purpose. Significant gaps. |
| 1 | Barely sketched out. Major functionality missing. |

---

## Overall Score Calculation

Average of all 6 dimension scores, rounded to nearest 0.5.

| Overall | Verdict |
|---------|---------|
| 4.5-5.0 | **PASS** — production quality |
| 3.5-4.4 | **PASS WITH WARNINGS** — functional, needs polish |
| 2.5-3.4 | **NEEDS WORK** — significant improvements needed |
| 1.0-2.4 | **FAIL** — fundamental issues to address |

Note: Any structural FAIL (Step 3) = automatic overall FAIL regardless of content scores.
