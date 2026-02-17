# Structural Validation Checks

Full checklist derived from the [Agent Skills specification](https://agentskills.io/specification) and [Anthropic's building guide](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf?hsLang=en).

---

## File Structure

| # | Check | Severity | Rule |
|---|-------|----------|------|
| S1 | `SKILL.md` exists | FAIL | Case-insensitive per spec, but uppercase `SKILL.md` recommended. Not `README.md` |
| S2 | No README.md | FAIL | Skills must not contain README.md, INSTALLATION_GUIDE.md, CHANGELOG.md, QUICK_REFERENCE.md |
| S3 | Folder is kebab-case | FAIL | Lowercase, hyphens only. No spaces, underscores, capitals |
| S4 | Clean directory | WARN | No `.git/`, `node_modules/`, `.DS_Store`, `__pycache__/` |

## Frontmatter

| # | Check | Severity | Rule |
|---|-------|----------|------|
| F1 | YAML delimiters present | FAIL | Must start with `---` and close with `---` |
| F2 | `name` field present | FAIL | Required |
| F3 | `name` is kebab-case | FAIL | 1-64 chars. Lowercase alphanumeric + hyphens only |
| F4 | `name` no leading/trailing hyphen | FAIL | Must not start or end with `-` |
| F5 | `name` no consecutive hyphens | FAIL | Must not contain `--` |
| F6 | `name` matches directory | FAIL | Parent folder name must equal `name` value |
| F7 | `name` not reserved | FAIL | Must not contain `claude` or `anthropic` |
| F8 | `description` field present | FAIL | Required, non-empty |
| F9 | `description` ≤1024 chars | FAIL | Hard limit |
| F10 | No XML tags in frontmatter | FAIL | No `<` or `>` characters anywhere in frontmatter |
| F11 | `description` has WHAT | WARN | Should describe what the skill does |
| F12 | `description` has WHEN | WARN | Should describe when/trigger conditions |
| F13 | `description` has trigger phrases | WARN | Should include specific user utterances |
| F14 | `compatibility` ≤500 chars | FAIL | Hard limit if field present |
| F15 | `license` present | INFO | Recommended for open-source skills |

## Body Content

| # | Check | Severity | Rule |
|---|-------|----------|------|
| B1 | Body is non-empty | FAIL | Must have instructions after frontmatter |
| B2 | Body <500 lines | WARN | Per spec; move detail to references/ |
| B3 | Body <5000 words | WARN | Per Anthropic guide |
| B4 | Has step-by-step instructions | WARN | Should have numbered/ordered workflow |
| B5 | Has examples | WARN | At least one concrete usage example |
| B6 | Has error handling | WARN | Troubleshooting or failure guidance |
| B7 | No duplicate content | WARN | Info should live in SKILL.md OR references/, not both |

## References & Resources

| # | Check | Severity | Rule |
|---|-------|----------|------|
| R1 | References are 1-level deep | WARN | No deeply nested reference chains |
| R2 | Reference files <10k words each | WARN | Keep focused for context efficiency |
| R3 | References clearly linked from SKILL.md | WARN | Body should mention when to consult each reference |
| R4 | Scripts are self-contained | WARN | Document dependencies clearly |
| R5 | Scripts have error handling | WARN | Helpful error messages, edge case handling |
| R6 | Assets not meant for context loading | INFO | assets/ = output files, not instructions |

## Token Efficiency

| # | Check | Severity | Rule |
|---|-------|----------|------|
| T1 | No redundant Claude knowledge | WARN | Don't explain things Claude already knows |
| T2 | Concise examples over verbose prose | WARN | Show, don't tell |
| T3 | Deterministic ops use scripts | INFO | Sorting, validation, extraction = scripts not tokens |
| T4 | Mutually exclusive contexts separated | INFO | Different files for different paths |
