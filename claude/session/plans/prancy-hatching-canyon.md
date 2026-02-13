# Plan: Task-Planner Hook Gaps + Pure Orchestrator

9 changes across ~12 files. Fixes crash handling, artifact verification, tool bypasses, and extracts Phase 4 into a dedicated agent.

---

## Change 1: MultiEdit block in `block-direct-edits.sh` [TRIVIAL]

**File:** `~/.dotfiles/.claude/hooks/PreToolUse/block-direct-edits.sh`

Line 20: `Edit|Write)` → `Edit|Write|MultiEdit)`

---

## Change 2: MultiEdit in `parse-files-modified.sh` [TRIVIAL]

**File:** `~/.dotfiles/.claude/hooks/helpers/parse-files-modified.sh`

Add `MultiEdit` to the tool name check so files modified via MultiEdit are tracked.

---

## Change 3: Fix premature `.task_graph` cleanup [TRIVIAL]

**File:** `~/.dotfiles/.claude/hooks/SubagentStop/cleanup-subagent-flag.sh`

Remove line 24 (`rm -f .task_graph`). Parallel SubagentStop hooks may still need it. `cleanup-stale-subagents.sh` handles stale files (>60min).

---

## Change 4: Artifact verification in `advance-phase.sh` [LOW]

**File:** `~/.dotfiles/.claude/hooks/SubagentStop/advance-phase.sh`

After the case statement (line 80), before writing state: verify expected artifact exists on disk.

- `specify` → check `spec_file` exists
- `architecture` → check `plan_file` exists
- If missing → don't advance, log error, exit 0

---

## Change 5: Crash detection + `failed` status in `update-task-status.sh` [MEDIUM]

**File:** `~/.dotfiles/.claude/hooks/SubagentStop/update-task-status.sh`

**Decisions (user-confirmed):**
- Mark ALL executing tasks as failed when crash detected (aggressive, recoverable)
- Auto-retry up to 2 times (adds `retry_count` field)

**Logic:**
1. Extract `AGENT_TYPE` early (move up from line 34)
2. After `[[ -z "$TASK_ID" ]] && ...` — if agent is impl type + no parseable output:
   - Read `executing_tasks` from state
   - Mark ALL as `failed` with `failure_reason`
   - Remove from `executing_tasks`
3. New status: `in_progress → failed` (alongside existing `in_progress → implemented`)
4. Add `retry_count` field (default 0, incremented on re-spawn)

---

## Change 6: `validate-task-graph.sh` helper [NEW FILE]

**File:** `~/.dotfiles/.claude/hooks/helpers/validate-task-graph.sh`

Schema validation for task graph JSON. Checks:
- Required top-level fields: `plan_title`, `plan_file`, `spec_file`, `tasks[]`
- Per task: `id` (T\d+), `description`, `agent` (known list), `wave` (int ≥1), `depends_on` (array)
- Dependency validation: no self-deps, deps must exist, deps must be in earlier waves
- Agent validation: must be in recognized list
- `spec_anchors` must be array if present
- `new_tests_required` must be boolean if present
- `plan_context` and `file_list` allowed empty (legitimate for some tasks)

---

## Change 7: `phase-decompose.md` template [NEW FILE]

**File:** `~/.dotfiles/.claude/skills/task-planner/templates/phase-decompose.md`

Template for decompose-agent. Receives:
- `{feature_description}`, `{spec_file_path}`, `{plan_file_path}`

Contains:
- Available agents table
- Decompose rules (impl tasks include tests, sizing heuristics, test requirement rules)
- **Required JSON output format** with per-task fields: `id`, `description`, `agent`, `wave`, `depends_on`, `spec_anchors`, `new_tests_required`, `plan_context`, `file_list`

Agent outputs pure JSON — orchestrator validates + creates artifacts.

---

## Change 8: Update `SKILL.md` [DOC]

**File:** `~/.dotfiles/.claude/skills/task-planner/SKILL.md`

- **Phase 4:** Replace inline decompose with: spawn `decompose-agent` → validate JSON output → user approval → create GH issue + state file
- **State machine:** Add `failed` status + `retry_count` field
- **Execute phase:** Add auto-retry logic — detect `failed` tasks, re-spawn up to `retry_count < 2`
- **Constraints:** Document `start_sha` as legitimate PreToolUse write exception
- **Hook table:** Add `advance-phase.sh` (with artifact verification note)

Also update `validate-phase-order.sh` to recognize `decompose-agent` → `"decompose"` phase.

---

## Change 9: `wave-gate/SKILL.md` — use `files_modified` [DOC]

**File:** `~/.dotfiles/.claude/skills/wave-gate/SKILL.md`

Replace keyword heuristic algorithm (lines 99-103) with:
1. Read `task.files_modified` (set by `update-task-status.sh` hook)
2. Fallback to all wave changes if empty
3. Pass to review-invoker: `--files {files_modified}`

---

## Execution Order

| # | Change | Files | Effort |
|---|--------|-------|--------|
| 1 | MultiEdit block | `block-direct-edits.sh` | 1 line |
| 2 | MultiEdit parse | `parse-files-modified.sh` | 1 line |
| 3 | Premature cleanup | `cleanup-subagent-flag.sh` | Remove 1 line |
| 4 | Artifact verification | `advance-phase.sh` | ~20 lines |
| 5 | Crash detection | `update-task-status.sh` | ~35 lines |
| 6 | Schema validator | `validate-task-graph.sh` (new) | ~90 lines |
| 7 | Decompose template | `phase-decompose.md` (new) | ~70 lines |
| 8 | SKILL.md updates | `SKILL.md` + `validate-phase-order.sh` | Doc rewrite |
| 9 | Wave-gate update | `wave-gate/SKILL.md` | Doc edit |

## Verification

1. **MultiEdit block:** Create active_task_graph.json, attempt MultiEdit — should be blocked
2. **Artifact verification:** Simulate missing spec_file in state, verify advance-phase.sh doesn't advance
3. **Crash detection:** Run update-task-status.sh with empty transcript + impl agent type — verify tasks marked failed
4. **Schema validator:** Feed valid + invalid JSON — verify exit codes + error messages
5. **Decompose template:** Manual review of JSON contract completeness
6. **SKILL.md:** Read through for consistency with hook behavior
