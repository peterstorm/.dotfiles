# Agents vs Skills

## Skills (`.claude/skills/SKILL.md`)

- Invoked via `/skill-name` slash command
- Run **in-context** — inject instructions into current session
- Have full conversation history
- Support back-and-forth with user
- Static file imports via frontmatter `imports:` field
- **Use when**: interactive workflows, guidelines, shaping Claude's behavior in the current conversation

## Agents (`.claude/agents/*.md`)

- Spawned as **sub-agents** (separate processes)
- Own model choice (haiku for cheap/fast, opus for complex)
- Run in **parallel** with other agents
- Own tool access (can be restricted per agent)
- Return a result and exit — no user interaction during execution
- Can discover and load files at runtime via `Read`, `Glob`, `Grep` tools
- **Use when**: autonomous tasks, parallelizable work, delegation

## Decision Rule

**Skill** = "tell Claude how to behave right now" (needs dialogue, guides output)
**Agent** = "go do this thing and come back with results" (autonomous, fire-and-forget)

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

| Keep as Skill | Convert to Agent |
|---|---|
| brainstorming (needs dialogue) | code-reviewer (autonomous, parallelizable) |
| writing-clearly (guides output) | security-expert (scan independently) |
| architecture-tech-lead (interactive design) | test engineers (run autonomously) |
| marketing skills (need user input) | comment-analyzer, silent-failure-hunter |
| dotfiles-expert (interactive) | type-design-analyzer |
| mcp-expert (interactive guidance) | pr-test-analyzer |

## File Locations

```
~/.dotfiles/claude/
  global/skills/         # always active skills (brainstorming, writing-clearly)
  project/code/agents/   # general code agents (code-reviewer, security, etc.)
  project/java/agents/   # java-specific agents
  project/typescript/agents/  # ts-specific agents
  project/*/skills/      # project-pickable skills
```
