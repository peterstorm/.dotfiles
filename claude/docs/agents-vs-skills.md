# Agents vs Skills

## Skills (`.claude/skills/<name>/SKILL.md`)

- Invoked via `/skill-name`, or auto-triggered when the description matches the task
- Run **in-context** by default — inject instructions into the current session
- Have full conversation history; support back-and-forth with the user
- Reference companion files in the skill directory (`references/`, `assets/`),
  read on demand — there is no `imports:` frontmatter field
- Optional frontmatter changes the execution model:
  - `context: fork` — runs the skill in an isolated subagent context
  - `agent: <type>` — which agent type executes a forked skill
  - `allowed-tools`, `disable-model-invocation`, `background`
- **Use when**: interactive workflows, guidelines, shaping Claude's behavior in
  the current conversation

## Agents (`.claude/agents/*.md`)

- Spawned as **sub-agents** — separate context windows (not separate OS processes)
- Own model choice (haiku for cheap/fast, opus/fable for complex)
- Run in **parallel** with other agents
- Own tool access (can be restricted per agent)
- Return a result and exit — no user interaction during execution
- Can discover and load files at runtime via `Read`, `Glob`, `Grep` tools
- **Use when**: autonomous tasks, parallelizable work, delegation

## Decision Rule

**Skill** = "tell Claude how to behave right now" (needs dialogue, guides output)
**Agent** = "go do this thing and come back with results" (autonomous, fire-and-forget)

The boundary is softer than it used to be: commands and skills are unified
(both surface as invocable skills), and a skill with `context: fork` behaves
like a one-shot agent. The rule of thumb still holds — if it needs the
conversation, keep it in-context; if it's autonomous, fork or delegate.

## Dynamic Rule Loading for Agents

Agent `.md` files are static — no conditional imports. Two mechanisms for context-aware behavior:

### 1. Runtime discovery (agent-driven)
Instruct the agent to discover relevant rules based on language/context:
```markdown
When reviewing code, use Glob to find matching rules in .claude/rules/
based on the file language, then Read and apply them.
```

### 2. Path-based rules (automatic)
Rules in `.claude/rules/` with `paths:` frontmatter auto-load when Claude works with matching files:
```markdown
---
paths:
  - "src/**/*.ts"
---
# TypeScript-specific rules loaded automatically
```
The second approach is cleaner — rules inject themselves, agent doesn't need to know about them.

## Categorization Guide

| Keep as Skill | Run as Agent |
|---|---|
| brainstorming (needs dialogue) | loom:code-reviewer (autonomous, parallelizable) |
| writing-clearly (guides output) | loom:security-agent (scan independently) |
| loom:architecture-tech-lead (interactive design) | loom:java-test-agent / loom:ts-test-agent |
| marketing skills (need user input) | loom:comment-analyzer, loom:silent-failure-hunter |
| mcp-expert (interactive guidance) | loom:type-design-analyzer, loom:pr-test-analyzer |

The general code agents all ship in the **loom plugin** now (`loom:` prefix);
only repo-specific agents (e.g. `dotfiles-agent`) live in this dotfiles tree.

## File Locations

```
~/.dotfiles/claude/
  global/skills/           # always-active skills (brainstorming lives in loom now)
  project/meta/skills/     # cross-domain skills (mcp-expert, skill-creator, ...)
  project/meta/agents/     # repo-specific agents (dotfiles-agent)
  project/java/skills/     # java-specific skills
  project/typescript/      # ts skills + rules
  project/marketing/skills/  # marketing/CRO pack
```
