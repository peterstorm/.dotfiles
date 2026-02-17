---
name: skill-creator
version: 1.0.0
description: "This skill should be used when the user asks to 'create a skill', 'build a skill', 'make a skill', 'new skill', 'write a skill', 'skill for X', or wants to package a workflow as a reusable Claude Code skill. Guides through use case definition, frontmatter, instructions, testing, and file structure. NOT for reviewing existing skills — use /skill-content-reviewer instead."
---

# Skill Creator

Interactive guide for creating well-structured Claude Code skills. Walks through use case definition, frontmatter generation, instruction writing, reference organization, and validation.

**This is a DESIGN + BUILD skill** — first plan the skill, then generate the files.

Based on [The Complete Guide to Building Skills for Claude](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf?hsLang=en) by Anthropic.

---

## Workflow

### Step 1: Define Use Cases

Before writing anything, identify 2-3 concrete use cases.

Ask the user:
1. What task should this skill automate or guide?
2. What would a user say to trigger it? (collect 3-5 trigger phrases)
3. Which category fits best?
   - **Document/Asset Creation** — consistent output generation
   - **Workflow Automation** — multi-step processes with validation gates
   - **MCP Enhancement** — workflow guidance on top of MCP tool access

Capture:
- Target outcome per use case
- Required tools (built-in, MCP, scripts)
- Domain knowledge to embed

### Step 2: Plan Structure

Choose complexity level based on content size:

| Level | Structure | When |
|-------|-----------|------|
| Light | SKILL.md only | < 200 lines, single workflow |
| Medium | SKILL.md + references/ | 200-600 lines, multiple sub-topics |
| Heavy | SKILL.md + AGENTS.md + references/ + rules/ | 600+ lines, framework-level |

Plan the folder layout:

```
skill-name/
├── SKILL.md              # Required — main instructions
├── references/           # Optional — detailed docs
│   ├── topic-a.md
│   └── topic-b.md
├── scripts/              # Optional — executable code
├── assets/               # Optional — templates, icons
└── examples/             # Optional — example implementations
```

### Step 3: Write Frontmatter

Generate YAML frontmatter following these rules:

**Required fields:**
- `name`: kebab-case, matches folder name, no spaces/capitals
- `description`: WHAT it does + WHEN to use it + trigger phrases. Max 1024 chars. No XML tags.

**Optional fields:**
- `version`: semver string
- `license`: MIT, Apache-2.0, etc.
- `allowed-tools`: space-separated tool list (e.g., `"Bash(python:*) WebFetch Read"`)
- `metadata`: author, version, mcp-server, tags, etc.
- `compatibility`: environment requirements (1-500 chars)

**Frontmatter template:**
```yaml
---
name: my-skill-name
description: "This skill should be used when the user asks to '[trigger phrase 1]', '[trigger phrase 2]', or [broader description]. [What it does in one sentence]."
---
```

**Critical rules:**
- File MUST be named `SKILL.md` (case-insensitive per spec, but uppercase recommended)
- Folder MUST be kebab-case
- No `claude` or `anthropic` in skill name (reserved)
- No XML angle brackets in frontmatter
- Description MUST include both WHAT and WHEN

See `references/description-examples.md` for good/bad examples.

### Step 4: Write Instructions

Structure the SKILL.md body using this template:

```markdown
# Skill Name

Brief overview — what problem this solves.

---

## When to Use This Skill

Bullet list of trigger conditions.

## Workflow / Instructions

### Step 1: [First Major Step]
Clear explanation with actionable details.

### Step 2: [Next Step]
Include validation/checks between steps.

## Examples

Example 1: [common scenario]
User says: "..."
Actions: ...
Result: ...

## Troubleshooting

Error: [Common error]
Cause: [Why]
Solution: [Fix]

## Constraints

- Hard rules the skill must follow
```

**Instruction quality checklist:**
- Specific and actionable (not "validate things properly")
- Critical instructions at the top
- Bullet points and numbered lists over prose
- Reference bundled resources explicitly (`references/api-patterns.md`)
- Include error handling for common failures
- Add examples with expected inputs/outputs
- Keep SKILL.md under 5,000 words — move detail to references/

### Step 5: Write Reference Files (if needed)

For medium/heavy skills, create reference files:

- Each file focused on one sub-topic
- Track token costs in a reference table in SKILL.md:

```markdown
| Section | File | ~Tokens |
|---------|------|---------|
| Topic A | `references/topic-a.md` | 2,500 |
| Topic B | `references/topic-b.md` | 4,500 |
```

### Step 6: Validate

Run through this checklist before finalizing:

**Structure:**
- [ ] Folder is kebab-case
- [ ] SKILL.md exists (exact case)
- [ ] YAML frontmatter has `---` delimiters
- [ ] `name` field is kebab-case, matches folder
- [ ] `description` includes WHAT + WHEN + trigger phrases
- [ ] No XML tags in frontmatter

**Content:**
- [ ] Instructions are specific and actionable
- [ ] Error handling included
- [ ] Examples provided
- [ ] References clearly linked
- [ ] SKILL.md under 5,000 words

**Triggering (test mentally):**
- [ ] Triggers on obvious task phrases
- [ ] Triggers on paraphrased requests
- [ ] Does NOT trigger on unrelated topics

### Step 7: Place the Skill

Determine where the skill should live:

| Scope | Location |
|-------|----------|
| Open standard (portable) | `.github/skills/` in project root |
| Single project (Claude-specific) | `.claude/skills/` in project root |
| All projects (global) | `~/.dotfiles/claude/global/skills/` |
| Domain-specific (this dotfiles) | `~/.dotfiles/claude/project/{domain}/skills/` |

Prefer `.github/skills/` for open-source or cross-platform projects (works with Copilot, Codex, etc.). Use `.claude/skills/` for Claude-specific skills.

---

## Patterns Reference

Five common skill patterns — choose based on use case:

1. **Sequential Workflow** — ordered steps with dependencies and validation gates
2. **Multi-MCP Coordination** — phases spanning multiple services with data passing
3. **Iterative Refinement** — draft → validate → improve loops with quality thresholds
4. **Context-Aware Selection** — decision trees choosing tools based on input
5. **Domain Intelligence** — embedded expertise (compliance, best practices, standards)

See `references/patterns.md` for detailed examples.

---

## Troubleshooting

**Skill not triggering:**
- Description missing trigger phrases — add specific user utterances
- Description too vague — "helps with projects" won't match anything
- Wrong folder — verify skill is in a `.claude/skills/` or `.github/skills/` directory Claude discovers

**Description validation error (>1024 chars):**
- Move detail to SKILL.md body, keep description to WHAT + WHEN + triggers only
- Cut redundant trigger phrases — keep 3-5 most distinctive ones

**Skill not discovered:**
- Folder name doesn't match `name` field in frontmatter
- SKILL.md missing or wrong case
- Nested too deep — skills must be direct children of a `skills/` directory

**Skill loads but behaves wrong:**
- Instructions too vague — use specific verbs, not "validate properly"
- Missing constraints — add hard rules for what the skill must/must not do
- References not linked — Claude won't read files it doesn't know about

---

## Anti-Patterns

- Description too vague ("Helps with projects")
- Description missing trigger phrases
- Instructions too verbose — move detail to references
- All content inline instead of progressive disclosure
- Ambiguous language ("make sure to validate things properly")
- Missing error handling
- No examples

---

## Constraints

- MUST ask user for use cases before generating any files
- MUST validate frontmatter against rules before writing
- MUST use kebab-case for folder and name
- MUST include trigger phrases in description
- MUST place critical instructions at top of SKILL.md
- If skill has hooks/agents, note integration points but don't generate those here — use separate tools

---

## Step 8: Post-Creation Validation

After placing the skill, suggest running `/skill-content-reviewer` on it to validate structure, content quality, and triggering behavior.

---

## Example: Complete Minimal Skill

```
my-formatter/
└── SKILL.md
```

```yaml
---
name: my-formatter
version: 1.0.0
description: "This skill should be used when the user asks to 'format output', 'pretty print', 'clean up formatting', or needs consistent output formatting. Applies project formatting standards to generated content."
---

# My Formatter

Applies project-specific formatting standards to generated output.

## Workflow

### Step 1: Detect Content Type
Check if output is code, markdown, JSON, or prose.

### Step 2: Apply Rules
- Code: run project linter config
- Markdown: enforce heading hierarchy, link style
- JSON: 2-space indent, sorted keys
- Prose: sentence case headings, no trailing whitespace

### Step 3: Validate
Confirm formatting passes project checks. If not, re-apply.

## Constraints
- Never change content meaning — formatting only
- Preserve existing valid formatting choices
```
