# Move Loom to Claude Plugin

## Context
Loom orchestration system currently lives in `~/.claude/` (skills, agents, hooks, TS source). Every session loads all of it into context (~40k tokens). Moving to a plugin at `dev/claude-plugins/loom/` makes it lazy-loaded and self-contained.

## Target Structure

```
dev/claude-plugins/loom/
├── .claude-plugin/
│   └── plugin.json
├── commands/                          # skills → commands
│   ├── loom.md                        # from skills/loom/SKILL.md
│   ├── wave-gate.md                   # from skills/wave-gate/SKILL.md
│   ├── brainstorming.md               # from skills/brainstorming/SKILL.md
│   ├── specify.md                     # from skills/specify/SKILL.md
│   ├── clarify.md                     # from skills/clarify/SKILL.md
│   ├── code-implementer.md            # from skills/code-implementer/SKILL.md
│   ├── spec-check.md                  # from skills/spec-check/SKILL.md
│   └── templates/                     # from skills/loom/templates/
│       ├── phase-brainstorm.md
│       ├── phase-specify.md
│       ├── phase-clarify.md
│       ├── phase-architecture.md
│       ├── phase-decompose.md
│       └── impl-agent-context.md
├── agents/                            # agent definitions
│   ├── brainstorm-agent.md
│   ├── specify-agent.md
│   ├── clarify-agent.md
│   ├── architecture-agent.md
│   ├── decompose-agent.md
│   ├── code-implementer-agent.md
│   ├── review-invoker.md
│   └── spec-check-invoker.md
├── engine/                            # from hooks/loom/ (TS source)
│   ├── package.json
│   ├── bun.lock
│   ├── src/
│   │   ├── cli.ts
│   │   ├── config.ts
│   │   ├── types.ts
│   │   ├── state-manager.ts
│   │   ├── handlers/
│   │   ├── parsers/
│   │   └── utils/
│   └── tests/
├── hooks/
│   ├── hooks.json                     # all hook registrations (replaces settings.json entries)
│   └── scripts/                       # bash wrappers, rewritten with $CLAUDE_PLUGIN_ROOT
│       ├── validate-phase-order.sh
│       ├── validate-task-execution.sh
│       ├── validate-template-substitution.sh
│       ├── validate-agent-model.sh
│       ├── block-direct-edits.sh
│       ├── guard-state-file.sh
│       ├── mark-subagent-active.sh
│       ├── dispatch.sh
│       └── cleanup-stale-subagents.sh
└── references/
    └── plan-template.md               # from skills/loom/references/
```

## Steps

### 1. Create plugin scaffold
- `dev/claude-plugins/loom/.claude-plugin/plugin.json`
- `dev/claude-plugins/loom/hooks/hooks.json` with all loom hook registrations

### 2. Move engine (TS source)
- Copy `~/.claude/hooks/loom/{src,tests,package.json,bun.lock}` → `dev/claude-plugins/loom/engine/`
- Update path references in `config.ts` (use relative paths or `$CLAUDE_PLUGIN_ROOT`)

### 3. Move commands (skills)
- Copy each `skills/X/SKILL.md` → `commands/X.md`
- Copy `skills/loom/templates/` → `commands/templates/`
- Copy `skills/loom/references/` → `references/`
- Update any internal path references in SKILL.md files

### 4. Move agents
- Copy all 8 agent .md files → `agents/`
- Remove from `~/.claude/agents/`

### 5. Rewrite bash hook wrappers
- All wrappers use `$CLAUDE_PLUGIN_ROOT` instead of `~/.claude/hooks/loom/`
- Place in `hooks/scripts/`

### 6. Build hooks.json
Consolidate all hook registrations from settings.json into plugin hooks.json:

```json
{
  "description": "Loom orchestration hooks - phase validation, state guards, subagent lifecycle",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Task", "hooks": [
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/validate-phase-order.sh" },
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/validate-task-execution.sh" },
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/validate-template-substitution.sh" },
        { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/validate-agent-model.sh" }
      ]},
      { "matcher": "Edit", "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/block-direct-edits.sh" }]},
      { "matcher": "Write", "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/block-direct-edits.sh" }]},
      { "matcher": "MultiEdit", "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/block-direct-edits.sh" }]},
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/guard-state-file.sh" }]}
    ],
    "SubagentStart": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/mark-subagent-active.sh" }]}
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/dispatch.sh" }]}
    ],
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/cleanup-stale-subagents.sh" }]}
    ]
  }
}
```

### 7. Clean up settings.json
Remove ALL loom hook entries. Keep only:
- `send_event.sh` entries (stays separate)
- Non-loom settings (permissions, statusLine, etc.)

### 8. Clean up dotfiles
Delete moved files from `~/.claude/`:
- `skills/loom/`, `skills/wave-gate/`, `skills/brainstorming/`, `skills/specify/`, `skills/clarify/`, `skills/code-implementer/`, `skills/spec-check/`
- `agents/{brainstorm,specify,clarify,architecture,decompose,code-implementer,review-invoker,spec-check-invoker}-agent.md`
- `hooks/loom/`, `hooks/PreToolUse/`, `hooks/SubagentStop/`, `hooks/SubagentStart/`, `hooks/SessionStart/`

### 9. Update CLAUDE.md
`/loom` reference stays — plugin system resolves it. No change needed.

### 10. Install & verify
- `bun install` in engine/
- Enable plugin in settings.json `enabledPlugins`
- Test: `claude /loom --status` to verify skill loads

## Verification
1. `ls dev/claude-plugins/loom/` — structure matches plan
2. `grep -r "loom" ~/.claude/settings.json` — no loom hook refs remain
3. `ls ~/.claude/hooks/PreToolUse/` — empty or gone (except send_event.sh if it lived there)
4. `ls ~/.claude/agents/` — no loom agents remain
5. Start new session → `/loom --status` works
6. `/context` shows reduced token count

## Unresolved Questions
- Plugin system supports `agents/` dir? If not, agents stay in dotfiles or embed in commands
- `architecture-tech-lead` skill referenced standalone in CLAUDE.md — move to loom or keep both places?
- `java-test-agent`, `ts-test-agent`, `frontend-agent` etc in IMPL_AGENTS — general purpose, stay in dotfiles?
- `review-skill/SKILL.md` — is this the review-invoker's associated skill? Or is that `/review-pr` which is a finalize skill?
- Bash wrappers currently skip when no active task graph (`[ ! -f ... ] && exit 0`) — that pattern still works since state file is project-local
- `templates.md` in skills/loom/ — move to commands/ or references/?
