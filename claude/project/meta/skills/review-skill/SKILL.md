---
name: review-skill
version: "1.0.0"
description: "This skill should be used when the user asks to 'review skill', 'audit skill', 'check skill quality', 'review hooks', 'review plugin', or wants a comprehensive multi-agent review of a skill and its hooks/agents/helpers. Spawns a structural reviewer, skill-content-reviewer, and claude-code-guide in parallel."
---

# Review Skill - Multi-Agent Skill Auditor

Runs 3 specialized review agents in parallel against a skill and all its associated components (hooks, agents, helpers, tests).

---

## Arguments

- `/review-skill {skill-name}` — Review a specific skill (e.g., `loom`)
- `/review-skill {skill-name} --structure-only` — Only run Agent A (structural review)
- `/review-skill {skill-name} --content-only` — Only run Agent B (content quality)
- `/review-skill {skill-name} --hooks-only` — Only run Agent C (hooks best practices)

---

## Workflow

### 1. Resolve Skill Name

Parse the argument to get the skill name. If no argument provided, ask the user which skill to review.

### 2. Discover All Related Files

Search these locations for the skill, in order (first match wins for the primary SKILL.md; still sweep the rest for related files):

```
{exact path if provided}
.claude/skills/{skill-name}/                                → current project's skills
~/.dotfiles/claude/project/*/skills/{skill-name}/           → dotfiles domain skills (meta, typescript, java, marketing)
~/.dotfiles/claude/global/skills/{skill-name}/              → global skills
~/dev/claude-plugins/{plugin}/                              → plugin source repos (loom, cortex, feynman, reclaw)
~/.claude/plugins/cache/*/*/*/                              → installed plugin snapshots (skills/, commands/, agents/, hooks/)
```

**Discovery strategy:**

1. Read the skill's `SKILL.md` — this is the primary file
2. Glob `{skill-dir}/**/*` — all skill files (recursive: references/, assets/, scripts/, evals/)
3. If the skill belongs to a plugin, read the plugin's `.claude-plugin/plugin.json` and its `hooks/` directory — plugin hooks live inside the plugin, not in `~/.claude/hooks/`
4. Read `~/.claude/settings.json` — check for any directly registered hooks and enabled plugins
5. Grep the plugin's hook scripts and agents for references to the skill name or its state files

Build a **file inventory** — a categorized list of all discovered files with full paths.

### 3. Spawn Review Agents in Parallel

Launch **all three agents in a single message** (parallel execution):

#### Agent A: Structural Review (`general-purpose`)

```
Review the {skill-name} skill plugin and ALL its associated hooks, agents, and helpers for structural quality and best practices.

First read the structural checklist at ~/.dotfiles/claude/project/meta/skills/skill-content-reviewer/references/structural-checks.md and run every check.

Files to review:
{file inventory}

Additionally review for:
1. Plugin structure and conventions
2. Hook registration correctness
3. Agent definition quality
4. Skill frontmatter and content structure
5. Shell script quality and error handling
6. Inter-component consistency
```

#### Agent B: Content Quality (`skill-content-reviewer`)

```
Review the content quality of the {skill-name} skill and all its associated components.

Files to review:
{file inventory}

Evaluate:
1. Is the guidance comprehensive and actionable?
2. Are hook scripts doing the right things?
3. Are there gaps in coverage (missing edge cases, hooks)?
4. Is the content accurate — will it guide Claude Code correctly?
5. Are templates well-structured?
6. Do agent prompts give enough context?
```

#### Agent C: Hooks Best Practices (`claude-code-guide`)

```
I need expert guidance on Claude Code hooks best practices to evaluate the {skill-name} plugin.

This plugin uses these hooks:
{list hook events and scripts from file inventory}

Please verify:
1. Hook event usage — are the right events used for each purpose?
2. Hook registration format — is settings.json correct?
3. Input/output contracts — exit codes, stdin JSON, stderr usage
4. State management patterns — atomic writes, locking, file paths
5. Known limitations that apply to this plugin's hook usage
6. Any anti-patterns or gotchas in the hook implementations
```

### 4. Synthesize Results

After agents complete, present a unified summary. If an agent fails or returns empty output, note the failure and synthesize from the agents that succeeded — do not retry or block on the failed agent.

```
## Skill Review: {skill-name}

### Structural Review
{Agent A key findings — critical/major/minor counts}

### Content Quality
{Agent B key findings — gaps, strengths, accuracy}

### Hooks Compliance
{Agent C key findings — contract violations, anti-patterns}

### Priority Fixes
1. {most critical finding across all agents}
2. ...
```

---

## Constraints

- MUST spawn all 3 agents in a single message (parallel)
- MUST include full file paths in each agent prompt
- MUST present unified summary after all complete
- If `--structure-only`, `--content-only`, or `--hooks-only`, spawn only the relevant agent (A, B, or C respectively)
- If an agent fails or returns empty, synthesize from available results and note the gap
- If the target skill has no hooks, skip Agent C (hooks review) unless explicitly requested
- If skill not found, list available skills and ask user to pick one
