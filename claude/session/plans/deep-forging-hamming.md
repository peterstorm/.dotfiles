# Plan: Context bloat cleanup — skills, plugins, rules, agents

## Context
~18k tokens (9%) consumed by globally-loaded skills (51), agents (23), and rules (4). All symlinked from dotfiles → ~/.claude/. Additionally, local plugins (cortex 476MB, obsidian, feynman) bloat the dotfiles repo. Loom orchestration system is spread across skills/agents/hooks without being a proper plugin.

## Step 1: Delete all skills
All 51 skills in `.dotfiles/.claude/skills/` — delete entirely. Git has full history.
```bash
rm -rf ~/.dotfiles/.claude/skills/*
```
**Saves: ~6.7k tokens**

## Step 2: Move local plugins to ~/dev/claude-plugins/

### 2a. Create directory + move existing plugins
```bash
mkdir -p ~/dev/claude-plugins
mv ~/.dotfiles/.claude/plugins/cortex ~/dev/claude-plugins/cortex
mv ~/.dotfiles/.claude/plugins/obsidian ~/dev/claude-plugins/obsidian
mv ~/.dotfiles/.claude/plugins/feynman ~/dev/claude-plugins/feynman
```

Each already has internal structure (commands/, agents/, skills/, hooks/). Need to ensure each has `.claude-plugin/plugin.json` manifest (currently only in cache copies).

### 2b. Add manifests to source dirs
Create `.claude-plugin/plugin.json` in each plugin's root (copy from cache):
- `~/dev/claude-plugins/cortex/.claude-plugin/plugin.json`
- `~/dev/claude-plugins/obsidian/.claude-plugin/plugin.json`
- `~/dev/claude-plugins/feynman/.claude-plugin/plugin.json`

### 2c. Extract loom as proper plugin
Create `~/dev/claude-plugins/loom/` with this structure:
```
~/dev/claude-plugins/loom/
├── .claude-plugin/
│   └── plugin.json          # NEW manifest
├── skills/
│   ├── loom/                 # FROM .claude/skills/loom/ (already deleted in step 1, restore from git)
│   ├── wave-gate/            # FROM .claude/skills/wave-gate/
│   └── spec-check/           # FROM .claude/skills/spec-check/
├── agents/
│   ├── architecture-agent.md
│   ├── brainstorm-agent.md
│   ├── clarify-agent.md
│   ├── specify-agent.md
│   ├── decompose-agent.md
│   ├── review-invoker.md
│   ├── spec-check-invoker.md
│   └── code-implementer-agent.md
├── hooks/                    # FROM .claude/hooks/loom/ (TypeScript app)
│   ├── src/
│   ├── package.json
│   ├── tsconfig.json
│   └── vitest.config.ts
└── hook-shims/               # FROM .claude/hooks/PreToolUse/, SubagentStop/, etc.
    ├── PreToolUse/
    ├── SubagentStop/
    ├── SubagentStart/
    └── SessionStart/
```

**Source files to extract (from git if already deleted):**
- Skills: `loom/`, `wave-gate/`, `spec-check/` from `.claude/skills/`
- Agents: `architecture-agent.md`, `brainstorm-agent.md`, `clarify-agent.md`, `specify-agent.md`, `decompose-agent.md`, `review-invoker.md`, `spec-check-invoker.md`, `code-implementer-agent.md` from `.claude/agents/`
- Hooks TS app: `.claude/hooks/loom/` (entire directory)
- Hook shims: `.claude/hooks/PreToolUse/{block-direct-edits,guard-state-file,validate-agent-model,validate-phase-order,validate-task-execution,validate-template-substitution}.sh`
- Hook shims: `.claude/hooks/SubagentStop/dispatch.sh`, `.claude/hooks/SubagentStart/mark-subagent-active.sh`, `.claude/hooks/SessionStart/cleanup-stale-subagents.sh`
- Event bridge: `.claude/hooks/send_event.sh` (loom-tui event feed)

### 2d. Re-register plugins
```bash
claude plugin install ~/dev/claude-plugins/cortex
claude plugin install ~/dev/claude-plugins/obsidian
claude plugin install ~/dev/claude-plugins/feynman
claude plugin install ~/dev/claude-plugins/loom
```

## Step 3: Clean up agents
Remove loom agents from `.dotfiles/.claude/agents/` (now in loom plugin):
- architecture-agent.md, brainstorm-agent.md, clarify-agent.md, specify-agent.md
- decompose-agent.md, review-invoker.md, spec-check-invoker.md, code-implementer-agent.md

**Remaining agents** (15, still in dotfiles as project-level):
- code-reviewer.md, code-simplifier.md, comment-analyzer.md, pr-test-analyzer.md
- silent-failure-hunter.md, type-design-analyzer.md, skill-content-reviewer.md
- test-engineer.md, dotfiles-agent.md, frontend-agent.md
- java-test-agent.md, ts-test-agent.md, k8s-agent.md, keycloak-agent.md, security-agent.md

## Step 4: Clean up hooks in dotfiles
Remove all hook files that moved to loom plugin:
- Delete `.claude/hooks/loom/` (entire TS app)
- Delete `.claude/hooks/PreToolUse/` (all 6 are loom)
- Delete `.claude/hooks/SubagentStop/dispatch.sh`
- Delete `.claude/hooks/SubagentStart/mark-subagent-active.sh`
- Delete `.claude/hooks/SessionStart/cleanup-stale-subagents.sh`
- Delete `.claude/hooks/send_event.sh`

## Step 5: Clean up settings.json hooks
Remove loom hook definitions from `.dotfiles/.claude/settings.json`. Currently ALL hooks are loom-related. After cleanup, the hooks section is empty (or removed entirely). Loom plugin's own plugin.json will define its hooks.

**Before:** 8 hook event types, all calling loom scripts
**After:** empty hooks section (or just the plugin references)

## Step 6: Fix symlinks for rules
```bash
rm ~/.claude/rules                                    # remove directory symlink
mkdir ~/.claude/rules
ln -s ~/.dotfiles/.claude/rules/architecture.md ~/.claude/rules/architecture.md
```
**Saves: ~5.4k tokens** (removes java-patterns, typescript-patterns, property-testing from global)

## Step 7: Fix symlinks for agents
```bash
rm ~/.claude/agents                                   # remove directory symlink
mkdir ~/.claude/agents
# Symlink only cross-cutting agents globally
for a in code-reviewer code-simplifier; do
  ln -s ~/.dotfiles/.claude/agents/$a.md ~/.claude/agents/$a.md
done
```
**Saves: ~3.5k tokens** (13 agents no longer global)

## Step 8: Fix symlinks for skills
```bash
rm ~/.claude/skills                                   # remove directory symlink
mkdir ~/.claude/skills                                # empty - all skills are now plugin-provided or project-level
```
**Saves: ~6.7k tokens** (already done in step 1, this just fixes the symlink)

## Step 9: Update CLAUDE.md
Remove `See @rules/architecture.md` ref (auto-loaded globally now).
Keep `/architecture-tech-lead` ref (provided by loom plugin).

## Estimated total savings

| Category | Before | After | Saved |
|---|---|---|---|
| Rules | ~6,000 | ~600 | ~5,400 |
| Skills | ~6,700 | 0 (plugin-provided) | ~6,700 |
| Agents | ~5,200 | ~300 (2 global) | ~4,900 |
| **Total** | **~17,900** | **~900** | **~17,000** |

Plugin-provided skills/agents still load when plugins are enabled, but that's a separate concern (plugin scoping is a follow-up).

## Execution order
1. Step 2a first (move plugins before deleting skills, since loom skills need to be copied)
2. Actually: copy loom files to ~/dev/claude-plugins/loom/ FIRST, then delete
3. Steps 1, 3, 4, 5 (delete from dotfiles)
4. Steps 6, 7, 8 (fix symlinks)
5. Step 2d (re-register plugins)
6. Step 9 (update CLAUDE.md)

## Verification
1. `ls -la ~/.claude/{rules,skills,agents}` → individual symlinks, not directory symlinks
2. `ls ~/dev/claude-plugins/` → cortex, obsidian, feynman, loom
3. Start new session outside dotfiles → `/context` → confirm minimal token usage
4. `claude plugin list` → all 4 local plugins registered from new paths
5. In a test project, invoke `/loom` → confirm it works via plugin

## Unresolved questions
- Init git repos for each plugin in ~/dev/claude-plugins/, or one monorepo?
- Keep code-reviewer + code-simplifier agents global, or zero global agents?
- Loom plugin hook shims: rewrite paths to reference plugin dir instead of ~/.claude/?
