---
name: skill-content-reviewer
version: 1.0.0
description: "This skill should be used when the user asks to 'review a skill', 'audit skill quality', 'validate a skill', 'check my skill', 'improve my skill', 'skill feedback', or wants expert assessment of a SKILL.md against Anthropic best practices and the open Agent Skills specification. Performs structural validation, content quality analysis, triggering assessment, and token efficiency review. NOT for creating skills — use /skill-creator instead."
---

# Skill Content Reviewer

Expert reviewer for Claude Code / Agent Skills. Validates structure, content quality, triggering behavior, and token efficiency against the [Agent Skills specification](https://agentskills.io/specification) and [Anthropic's building guide](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf?hsLang=en).

---

## Arguments

- `/skill-content-reviewer {path-or-name}` — review a specific skill
- `/skill-content-reviewer` — no arg = ask user which skill to review

---

## Workflow

### Step 1: Locate & Read Skill

1. Resolve the skill path. Check in order:
   - Exact path provided
   - `.claude/skills/{name}/`
   - `.github/skills/{name}/`
   - `~/.dotfiles/claude/project/*/skills/{name}/`
   - `~/.dotfiles/claude/global/skills/{name}/`
2. Read `SKILL.md` and inventory all files in the skill directory
3. If not found, list available skills and ask user to pick

### Step 2: Research the Skill's Domain Content

**Verify the skill's domain advice is accurate and current** using WebSearch:

1. Identify the skill's domain (e.g., React, SEO, Java entities, marketing copy)
2. Search for current best practices in that domain: `{domain} best practices {year}`
3. Search for any recent changes or deprecations: `{domain} changes deprecated {year}`

Synthesize findings to verify whether the skill's instructions and references contain accurate, up-to-date domain knowledge. Flag any outdated advice, missing current patterns, or incorrect recommendations.

**Skip only if** the skill is purely procedural with no domain advice (e.g., a skill that just locates files or manages skill directories). The skill's folder location doesn't matter — an architecture skill in `meta/` still has domain content that needs verification.

### Step 3: Structural Validation

Run every check in `references/structural-checks.md` against the skill. Any FAIL = automatic overall FAIL. Record each result in the output table.

### Step 4: Content Quality Analysis

Score each of the 6 dimensions 1-5 using `references/quality-rubric.md`:

1. **Description Quality** — WHAT + WHEN + triggers, specificity balance
2. **Instruction Clarity** — actionable steps, examples, error handling
3. **Progressive Disclosure** — SKILL.md lean, references focused
4. **Degrees of Freedom** — freedom calibrated to task fragility
5. **Token Efficiency** — no redundant knowledge, concise examples
6. **Completeness** — use cases, edge cases, constraints, failure modes

### Step 5: Triggering Assessment

Mentally simulate triggering behavior:

**Should trigger (test 3-5 phrases):**
Generate realistic user utterances that SHOULD activate this skill. Check if the description would match.

**Should NOT trigger (test 2-3 phrases):**
Generate plausible but unrelated queries. Verify the description is specific enough to avoid false positives.

**Assess:**
- Over-triggering risk (description too broad)
- Under-triggering risk (description too narrow, missing keywords)
- Negative trigger presence (explicit "do NOT use for...")

### Step 6: Security Review

Quick scan for:
- Does skill direct Claude to untrusted external services?
- Do scripts have unclear dependencies?
- Are there network calls without user awareness?
- Any credential/secret handling concerns?

### Step 7: Domain Accuracy Assessment

Compare the skill's domain advice against Step 2 research:
1. Are the skill's instructions/references factually accurate for the domain?
2. Is any advice outdated or superseded by newer patterns?
3. Are there important domain best practices the skill misses?

Flag specific inaccuracies with corrected info. If Step 2 was skipped (meta/structural skill), note "N/A — no domain content to verify".

---

## Output Format

```markdown
## Skill Review: {skill-name}

### Summary
- **Overall Score**: X/5
- **Verdict**: PASS | PASS WITH WARNINGS | NEEDS WORK | FAIL
- **Top 3 Issues**: (prioritized)

### Structural Validation
| Check | Status | Detail |
|-------|--------|--------|
| ... | PASS/FAIL/WARN | ... |

### Content Quality Scores
| Dimension | Score | Notes |
|-----------|-------|-------|
| Description Quality | X/5 | ... |
| Instruction Clarity | X/5 | ... |
| Progressive Disclosure | X/5 | ... |
| Degrees of Freedom | X/5 | ... |
| Token Efficiency | X/5 | ... |
| Completeness | X/5 | ... |

### Triggering Assessment
- **Should trigger**: [phrases tested] — result
- **Should NOT trigger**: [phrases tested] — result
- **Risk**: over/under/balanced

### Security
- [findings or "No issues found"]

### Recommendations
1. [highest priority fix with specific guidance]
2. ...
3. ...

### Domain Accuracy
- [finding or "N/A — purely procedural skill, no domain advice to verify"]
```

---

## Example (abbreviated)

```markdown
## Skill Review: my-formatter

### Summary
- **Overall Score**: 4/5
- **Verdict**: PASS WITH WARNINGS
- **Top 3 Issues**: missing version, no error handling examples, description could add negative trigger

### Structural Validation
| Check | Status | Detail |
|-------|--------|--------|
| S1 SKILL.md exists | PASS | Correct case |
| F2 name present | PASS | `my-formatter` |
| F6 name matches dir | PASS | |
| F15 version | WARN | Missing |

### Content Quality Scores
| Dimension | Score | Notes |
|-----------|-------|-------|
| Description Quality | 4/5 | Good triggers, missing negative |
| Instruction Clarity | 4/5 | Clear steps, no error handling |
| Progressive Disclosure | 5/5 | Lean single-file skill |
| Degrees of Freedom | 4/5 | Rules are appropriately strict |
| Token Efficiency | 5/5 | Minimal, no fluff |
| Completeness | 3/5 | No troubleshooting section |

### Recommendations
1. Add `version: 1.0.0` to frontmatter
2. Add troubleshooting for linter config not found
3. Add negative trigger: "NOT for content generation"
```

If skill scores ≤2.5 overall, suggest rebuilding from scratch with `/skill-creator`.

---

## References

| Section | File | ~Tokens |
|---------|------|---------|
| Structural checks | `references/structural-checks.md` | ~1,500 |
| Quality rubric | `references/quality-rubric.md` | ~2,000 |

---

## Troubleshooting

**Can't find skill:**
- Check all search paths including `.github/skills/` (2026 standard location)
- Verify folder name matches `name` field in frontmatter
- Ask user for exact path if discovery fails

**Web search returns nothing relevant:**
- Niche or internal domain — fall back to embedded knowledge from references/
- Note in output that domain verification was limited

**Score seems wrong after review:**
- Re-read rubric dimension definitions in `references/quality-rubric.md`
- Check if structural FAILs are overriding content scores (any structural FAIL = overall FAIL)

---

## Constraints

- MUST web search the skill's domain content to verify accuracy (skip only for purely procedural skills with no domain advice)
- MUST read the entire SKILL.md before any assessment
- MUST check against the formal Agent Skills specification
- MUST provide actionable, specific recommendations (not "improve the description")
- MUST cite source for each recommendation (guide/spec/community/research)
- Score objectively — don't inflate scores to be polite
- If skill has scripts/, read and assess them for quality and security
- If skill has references/, assess their organization and token efficiency
