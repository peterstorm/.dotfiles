# Workflow Orchestration Analysis

Analysis of [barkain/claude-code-workflow-orchestration](https://github.com/barkain/claude-code-workflow-orchestration) and how to adopt its patterns.

## Their Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         HOOKS                                    │
├──────────────────┬─────────────────┬─────────────────┬──────────┤
│ UserPromptSubmit │   PreToolUse    │  SubagentStop   │ Session  │
│ (clear state)    │ (gate tools)    │ (verify+todo)   │ Start    │
└──────────────────┴─────────────────┴─────────────────┴──────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      TASK PLANNER SKILL                          │
│  - Decomposes tasks into subtasks                                │
│  - Assigns agents via keyword matching                           │
│  - Groups into parallel waves                                    │
│  - Outputs task graph + TodoWrite entries                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     SPECIALIZED AGENTS (8)                       │
│  tech-lead-architect | codebase-context-analyzer                 │
│  task-completion-verifier | code-cleanup-optimizer               │
│  code-reviewer | devops-experience-architect                     │
│  documentation-expert | dependency-manager                       │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** Hooks enforce the workflow, task-planner orchestrates, agents execute.

---

## Hook Patterns

### 1. PreToolUse - Tool Gating

**Their implementation:** Block Write/Edit/Bash unless `/delegate` was called first.

```bash
# Allowlist pattern - these always pass
ALLOWED_TOOLS="AskUserQuestion|TodoWrite|Skill|Task"

# State tracking
.claude/state/delegation_active    # flag file
.claude/state/delegated_sessions   # session IDs
.claude/state/active_delegations.json  # parallel tracking
```

**Adaptation for our setup:**

```bash
# .claude/hooks/PreToolUse/enforce-skill-usage.sh
# Force /code-implementer before writing code

TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')

# Allow research tools freely
[[ "$TOOL_NAME" =~ ^(Read|Glob|Grep|WebFetch|WebSearch|AskUserQuestion|TodoWrite)$ ]] && exit 0

# Check if implementation skill was invoked
if [[ ! -f ".claude/state/implementation_active" ]]; then
  echo "Use /code-implementer before writing code"
  exit 2
fi
```

### 2. SessionStart - Context Injection

**Their implementation:** Inject ~27k char orchestrator prompt on every session.

**Adaptation for our setup:**

```bash
# .claude/hooks/SessionStart/inject-architecture.sh
# Inject architecture rules into every session

cat <<'EOF'
<architecture-context>
## Active Session Rules
- FP style, immutability first
- Push I/O to edges
- 90%+ unit testable without mocks
- Use Either for error handling
</architecture-context>
EOF
```

### 3. SubagentStop - Post-Execution QA

**Their implementation:** Auto-spawn verifier agent after task completion.

**Adaptation for our setup:**

```bash
# .claude/hooks/SubagentStop/auto-review.sh
# Spawn code-reviewer after implementation agents

AGENT_TYPE="${SUBAGENT_TYPE:-unknown}"
AGENT_STATUS="${SUBAGENT_STATUS:-unknown}"

[[ "$AGENT_STATUS" != "completed" ]] && exit 0

# Skip if already a reviewer
[[ "$AGENT_TYPE" =~ (reviewer|verifier|analyzer) ]] && exit 0

echo "Implementation complete. Spawning code-reviewer for QA..."
```

### 4. UserPromptSubmit - State Cleanup

**Their implementation:** Clear all delegation state between prompts.

```bash
# .claude/hooks/UserPromptSubmit/clear-state.sh
rm -f .claude/state/implementation_active
rm -f .claude/state/active_task_graph.json
```

---

## Building Our Own Task Planner

### Core Concept

Task planner = decomposition + assignment + scheduling

```
Input: "Add user auth with JWT"
                │
                ▼
┌─────────────────────────────────┐
│        DECOMPOSITION            │
│  1. Design auth flow            │
│  2. Create user model           │
│  3. Implement JWT service       │
│  4. Add login endpoint          │
│  5. Add middleware              │
│  6. Write tests                 │
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│        AGENT ASSIGNMENT         │
│  1 → architecture-tech-lead     │
│  2 → code-implementer           │
│  3 → code-implementer           │
│  4 → code-implementer           │
│  5 → code-implementer           │
│  6 → java-test-engineer         │
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│        WAVE SCHEDULING          │
│  Wave 1: [1]        (design)    │
│  Wave 2: [2,3]      (parallel)  │
│  Wave 3: [4,5]      (parallel)  │
│  Wave 4: [6]        (tests)     │
└─────────────────────────────────┘
```

### Their Agent Assignment Algorithm

Keyword-based scoring (agent scores ≥2 matches wins):

```
architecture-tech-lead:
  keywords: [design, architecture, pattern, best practice, structure]

code-implementer:
  keywords: [implement, create, add, build, write code]

java-test-engineer:
  keywords: [test, junit, jqwik, coverage, assert]

security-expert:
  keywords: [auth, security, jwt, oauth, keycloak, vulnerability]
```

Fallback to `general-purpose` if no agent scores ≥2.

### Minimal Task Planner Skill

```markdown
---
description: Decompose tasks, assign agents, schedule waves
tools: [Read, Glob, Grep, Bash, AskUserQuestion, TodoWrite]
---

# Task Planner

## Process

1. **Parse Intent**
   - What is the user trying to achieve?
   - What are the success criteria?
   - Any ambiguities requiring clarification?

2. **Explore Codebase**
   - Find relevant files/patterns
   - Identify integration points
   - Note existing conventions

3. **Decompose**
   - Break into atomic subtasks
   - Each subtask = single responsibility
   - Identify dependencies between tasks

4. **Assign Agents**
   Match keywords to available agents:
   | Agent | Triggers |
   |-------|----------|
   | architecture-tech-lead | design, pattern, structure |
   | code-implementer | implement, create, build |
   | java-test-engineer | test, junit, property |
   | ts-test-engineer | vitest, playwright, react test |
   | security-expert | auth, jwt, keycloak |
   | code-reviewer | review, quality, check |

5. **Schedule Waves**
   - Wave 1: Tasks with no dependencies
   - Wave N: Tasks depending on Wave N-1
   - Maximize parallelism per wave

6. **Output**
   - Task table with: ID, description, agent, dependencies, wave
   - JSON task graph for hooks to validate
   - TodoWrite entries for tracking

## Output Format

### Task Table
| ID | Task | Agent | Depends | Wave |
|----|------|-------|---------|------|
| T1 | Design auth flow | architecture-tech-lead | - | 1 |
| T2 | Create user model | code-implementer | T1 | 2 |

### Task Graph JSON
```json
{
  "tasks": [
    {"id": "T1", "agent": "architecture-tech-lead", "deps": [], "wave": 1},
    {"id": "T2", "agent": "code-implementer", "deps": ["T1"], "wave": 2}
  ],
  "current_wave": 1
}
```

Save to `.claude/state/active_task_graph.json` for hook validation.

## Constraints
- Never implement code
- Only explore for planning context
- Must populate TodoWrite before returning
```

### Wave Validation Hook

```bash
# .claude/hooks/PreToolUse/validate-wave.sh
# Ensure tasks execute in wave order

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Task" ]] && exit 0

# Extract phase from prompt
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.prompt // empty')
PHASE_ID=$(echo "$PROMPT" | grep -oE 'Phase ID: (T[0-9]+)' | cut -d' ' -f3)

[[ -z "$PHASE_ID" ]] && {
  echo "Task invocation missing Phase ID"
  exit 2
}

# Check wave order
CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
TASK_WAVE=$(jq -r ".tasks[] | select(.id==\"$PHASE_ID\") | .wave" "$TASK_GRAPH")

[[ "$TASK_WAVE" -gt "$CURRENT_WAVE" ]] && {
  echo "Cannot execute $PHASE_ID (wave $TASK_WAVE) - current wave is $CURRENT_WAVE"
  exit 2
}
```

---

## Implementation Roadmap

### Phase 1: Hooks Foundation
- [ ] `SessionStart/inject-context.sh` - inject architecture rules
- [ ] `UserPromptSubmit/clear-state.sh` - reset between prompts
- [ ] State directory: `.claude/state/`

### Phase 2: Skill Enforcement
- [ ] `PreToolUse/enforce-skills.sh` - gate Write/Edit behind skills
- [ ] Track skill invocation in state files
- [ ] Allowlist for research tools

### Phase 3: Task Planner Skill
- [ ] Create `.claude/skills/task-planner/SKILL.md`
- [ ] Agent keyword mapping
- [ ] Wave scheduling algorithm
- [ ] Task graph JSON output

### Phase 4: Wave Orchestration
- [ ] `PreToolUse/validate-wave.sh` - enforce execution order
- [ ] `SubagentStop/advance-wave.sh` - progress tracking
- [ ] `SubagentStop/auto-verify.sh` - spawn reviewers

---

## Differences from Their Approach

| Aspect | Theirs | Ours |
|--------|--------|------|
| Philosophy | Strict enforcement via hooks | Skill-based guidance |
| Parallelism | Wave-based concurrent agents | Sequential with optional parallel |
| Agent breadth | 8 general agents | Domain-specific (keycloak, security) |
| /delegate cmd | Required for all tool use | Optional orchestration |

Our setup has deeper domain expertise but less orchestration automation. Task planner + hooks would add the automation layer while keeping specialized skills.

---

---

## Merged Concept: Task Planner + GitHub Issues

Combines automated task decomposition/orchestration with persistent GitHub Issue tracking.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    /task-planner SKILL                       │
│  1. Decompose task into subtasks                            │
│  2. Assign agents via keyword matching                      │
│  3. Schedule waves (parallel groups)                        │
│  4. CREATE GITHUB ISSUE with full plan                      │
│  5. Write task graph to .claude/state/                      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    GITHUB ISSUE (created)                    │
│  ## Phase 1: Design (Wave 1)                                │
│  - [ ] T1: Design auth flow @architecture-tech-lead         │
│                                                              │
│  ## Phase 2: Core Implementation (Wave 2)                   │
│  - [ ] T2: Create user model @code-implementer              │
│  - [ ] T3: Implement JWT service @code-implementer          │
│                                                              │
│  ## Execution Order                                         │
│  | ID | Task | Agent | Wave | Depends |                     │
│  | T1 | Design | arch-tech-lead | 1 | - |                   │
│  | T2 | User model | code-impl | 2 | T1 |                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    HOOKS (enforce + update)                  │
│  PreToolUse: validate wave order against task graph         │
│  SubagentStop: mark issue checkbox, advance wave            │
│  PRs: auto-link to issue via "Closes #123" or "Part of #123"|
└─────────────────────────────────────────────────────────────┘
```

### Why Both?

| Aspect | GitHub Issue Only | Task Planner Only | Merged |
|--------|-------------------|-------------------|--------|
| Plan storage | Persistent, human-readable | Ephemeral JSON | Both (synced) |
| Decomposition | Manual in plan mode | Automated | Automated → Issue |
| Progress tracking | Manual checkbox clicks | TodoWrite UI only | Auto-update checkboxes |
| Wave enforcement | None | Hooks validate | Hooks + issue reflects |
| Team visibility | Full (issue is public) | None (local state) | Full |
| PR linking | Manual | None | Auto via hook |

**Key insight:** GitHub Issues = source of truth for humans; `.claude/state/` = source of truth for hooks. Keep them synced.

---

### Artifact Storage & Lifecycle

Three distinct artifacts serve different purposes in the workflow:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ARTIFACT OVERVIEW                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────────┐                                               │
│  │  .claude/plans/      │  LOCAL DRAFT                                  │
│  │  {date}-{slug}.md    │  - Full detailed plan from plan mode          │
│  │                      │  - Reasoning, code examples, decisions        │
│  │                      │  - Created FIRST, before issue                │
│  │                      │  - Offline backup, iteration space            │
│  └──────────┬───────────┘                                               │
│             │                                                            │
│             │ user approves                                              │
│             ▼                                                            │
│  ┌──────────────────────┐                                               │
│  │  GitHub Issue #N     │  PRIMARY SOURCE OF TRUTH (humans)             │
│  │                      │  - Copy of full plan (not summary!)           │
│  │                      │  - Checkboxes for task tracking               │
│  │                      │  - Edit history via GitHub                    │
│  │                      │  - Team comments/discussion                   │
│  │                      │  - PRs auto-linked here                       │
│  └──────────┬───────────┘                                               │
│             │                                                            │
│             │ extract structured data                                    │
│             ▼                                                            │
│  ┌──────────────────────┐                                               │
│  │  .claude/state/      │  MACHINE-READABLE STATE (hooks)               │
│  │  active_task_graph   │  - Task IDs, agents, waves, deps, status      │
│  │  issue_number        │  - Used by hooks for validation               │
│  │  current_wave        │  - Synced with issue checkboxes               │
│  └──────────────────────┘                                               │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

#### 1. Local Plan Draft (`.claude/plans/`)

**Purpose:** Detailed prose, reasoning, architectural decisions - the "why" behind the plan.

**Location:** `.claude/plans/{YYYY-MM-DD}-{task-slug}.md`

**Contents:**
- Full plan mode output (unchanged from current behavior)
- Architecture rationale
- Code examples and patterns
- Alternative approaches considered
- Integration points analysis
- Risk assessment

**Lifecycle:**
```
Plan Mode Entry → Write draft → User reviews → User approves
                      ↑                              │
                      └── iterate if needed ────────┘
```

**Why keep it?**
- Works offline (no GitHub dependency)
- Draft space before committing to issue
- Local reference during execution
- Can iterate privately before publishing
- Backup if issue is deleted/lost

#### 2. GitHub Issue (Primary Human Source of Truth)

**Purpose:** Persistent, team-visible plan with progress tracking.

**Location:** Repository issues (e.g., `#42`)

**Contents:**
- **Full plan copied from `.claude/plans/`** (not a summary!)
- Task checkboxes (auto-updated by hooks)
- Execution order table
- Verification checklist
- Related PRs section (auto-populated)

**Lifecycle:**
```
Plan approved → Create issue → Execute waves → Update checkboxes → Link PRs → Close on completion
                                    ↑                  │
                                    └── per task ──────┘
```

**Why GitHub Issue as primary?**
- Survives branch switches, machine changes, repo clones
- Team visibility without sharing local files
- Edit history tracked by GitHub
- Discussion via comments
- PR linking is native GitHub feature
- Searchable, filterable, assignable

**Critical:** The issue contains the FULL detailed plan, not just checkboxes. When someone opens the issue, they should understand the entire approach without needing local files.

#### 3. Machine State (`.claude/state/`)

**Purpose:** Structured data for hook validation and automation.

**Location:** `.claude/state/` directory

**Files:**
```
.claude/state/
├── active_task_graph.json   # Structured task data
├── issue_number             # GitHub issue # for this plan
├── current_wave             # Active wave number
├── plan_file                # Path to local plan draft
└── completed_tasks          # Task IDs marked done
```

**active_task_graph.json schema:**
```json
{
  "plan_file": ".claude/plans/2025-01-22-user-auth.md",
  "issue": 42,
  "current_wave": 2,
  "tasks": [
    {
      "id": "T1",
      "description": "Design auth flow and data model",
      "agent": "architecture-tech-lead",
      "wave": 1,
      "depends_on": [],
      "status": "completed",
      "completed_at": "2025-01-22T10:30:00Z"
    },
    {
      "id": "T2",
      "description": "Create User domain model",
      "agent": "code-implementer",
      "wave": 2,
      "depends_on": ["T1"],
      "status": "in_progress",
      "started_at": "2025-01-22T10:35:00Z"
    }
  ]
}
```

**Why separate from issue?**
- Hooks need fast local access (no API calls)
- Structured format for programmatic validation
- Status tracking more granular than checkboxes
- Can include metadata issue doesn't need (timestamps, etc.)

#### Sync Strategy

The three artifacts must stay in sync:

```
                    ┌─────────────────┐
                    │ .claude/plans/  │
                    │ (detailed plan) │
                    └────────┬────────┘
                             │
                     copy on create
                             │
                             ▼
┌─────────────────┐    ┌─────────────────┐
│ .claude/state/  │◄───│  GitHub Issue   │
│ (task graph)    │    │  (full plan +   │
└────────┬────────┘    │   checkboxes)   │
         │             └────────┬────────┘
         │                      │
         │    SubagentStop      │
         │    hook syncs        │
         └──────────────────────┘
              checkboxes
```

**Sync points:**
1. **Plan creation:** Local draft → Issue (copy) + State (extract)
2. **Task completion:** State updated → Issue checkbox marked
3. **Wave advancement:** State updated → (optionally) Issue comment
4. **PR creation:** Hook adds issue link → Issue shows in "Related PRs"

**Conflict handling:**
- State is authoritative for task status (hooks control it)
- If human edits issue checkboxes manually, next hook run re-syncs from state
- Plan content in issue is immutable after creation (edit local draft, create new issue if major changes)

#### Complete Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         COMPLETE ARTIFACT FLOW                           │
└─────────────────────────────────────────────────────────────────────────┘

User: "Add user auth with JWT"
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  /task-planner (or EnterPlanMode + manual decomposition)                 │
│                                                                          │
│  1. Explore codebase                                                     │
│  2. Decompose into tasks                                                 │
│  3. Assign agents, schedule waves                                        │
│  4. Write detailed plan                                                  │
└─────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  WRITE: .claude/plans/2025-01-22-user-auth.md                            │
│                                                                          │
│  Contains:                                                               │
│  - Full reasoning and analysis                                           │
│  - Architecture decisions                                                │
│  - Code examples                                                         │
│  - Task breakdown with agents                                            │
│  - Wave schedule                                                         │
│  - Verification checklist                                                │
└─────────────────────────────────────────────────────────────────────────┘
            │
            │ User approves plan
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  PARALLEL WRITES:                                                        │
│                                                                          │
│  ┌─────────────────────────────┐  ┌─────────────────────────────┐       │
│  │  gh issue create            │  │  Write state files          │       │
│  │  --title "Plan: User Auth"  │  │                             │       │
│  │  --body "$(cat plan.md)"    │  │  active_task_graph.json     │       │
│  │                             │  │  issue_number               │       │
│  │  → Returns issue #42        │  │  current_wave (= 1)         │       │
│  └─────────────────────────────┘  └─────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  EXECUTION LOOP (per wave)                                               │
│                                                                          │
│  For each task in current_wave:                                          │
│    1. PreToolUse hook validates wave order                               │
│    2. Agent executes task                                                │
│    3. SubagentStop hook:                                                 │
│       - Updates task status in active_task_graph.json                    │
│       - Marks checkbox in issue #42 via `gh issue edit`                  │
│       - If wave complete, increments current_wave                        │
│    4. Repeat until all waves done                                        │
└─────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  PR CREATION                                                             │
│                                                                          │
│  PreToolUse hook on `gh pr create`:                                      │
│    - Injects "Part of #42" into PR body                                  │
│    - Issue #42 now shows PR in sidebar                                   │
└─────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  COMPLETION                                                              │
│                                                                          │
│  All tasks done:                                                         │
│    - All checkboxes marked in issue                                      │
│    - PRs linked                                                          │
│    - Optionally: `gh issue close 42`                                     │
│    - State files can be cleared or archived                              │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Benefits of Three-Artifact Approach

| Benefit | How Achieved |
|---------|--------------|
| **No lost plans** | Local draft persists even if issue deleted |
| **Team visibility** | Issue is public, shows progress |
| **Offline capable** | Local draft + state work without GitHub |
| **Fast hook execution** | State files are local, no API latency |
| **Audit trail** | Issue history, PR links, timestamps in state |
| **Iteration friendly** | Edit local draft, create new issue if needed |
| **Branch-independent** | Issue persists across branch switches |
| **Searchable** | GitHub issue search, local grep |

---

### Workflow

1. **User invokes `/task-planner`** (or auto-triggered for complex tasks)
2. **Skill explores codebase** - finds relevant files, patterns, integration points
3. **Decomposes** into atomic subtasks with dependencies
4. **Assigns agents** via keyword matching (see table in Task Planner section)
5. **Schedules waves** - groups parallelizable tasks
6. **Creates GitHub Issue** with full plan:
   - Phases with checkboxes
   - Execution order table
   - Verification checklist
7. **Writes local state:**
   - `.claude/state/active_task_graph.json` - for hook validation
   - `.claude/state/issue_number` - for linking
8. **Execution proceeds** wave by wave
9. **SubagentStop hook** after each task:
   - Marks checkbox in GitHub issue via `gh`
   - Advances wave counter if all wave tasks complete
10. **PRs auto-linked** to issue (hook adds "Part of #X" to commit/PR)

### Sample GitHub Issue Output

```markdown
## Implementation Plan: Add User Auth with JWT

**Tracking Issue** - Auto-generated by task-planner

### Phase 1: Architecture (Wave 1)
- [ ] T1: Design auth flow and data model

### Phase 2: Core Implementation (Wave 2, parallel)
- [ ] T2: Create User domain model
- [ ] T3: Implement JWT token service

### Phase 3: API Layer (Wave 3, parallel)
- [ ] T4: Add login/register endpoints
- [ ] T5: Add auth middleware

### Phase 4: Verification (Wave 4)
- [ ] T6: Write property tests for auth logic
- [ ] T7: Integration tests for endpoints

---

### Execution Order

| ID | Task | Agent | Wave | Depends |
|----|------|-------|------|---------|
| T1 | Design auth flow | architecture-tech-lead | 1 | - |
| T2 | User domain model | code-implementer | 2 | T1 |
| T3 | JWT token service | code-implementer | 2 | T1 |
| T4 | Login endpoints | code-implementer | 3 | T2, T3 |
| T5 | Auth middleware | code-implementer | 3 | T3 |
| T6 | Property tests | java-test-engineer | 4 | T2, T3 |
| T7 | Integration tests | java-test-engineer | 4 | T4, T5 |

### Verification Checklist
- [ ] All tests pass
- [ ] No mock-heavy tests (architecture check)
- [ ] Security review completed
- [ ] PR linked and reviewed

### Related PRs
<!-- Auto-updated by hooks -->
```

### Hook: Update Issue Checkbox

```bash
# .claude/hooks/SubagentStop/update-issue.sh

ISSUE_FILE=".claude/state/issue_number"
TASK_GRAPH=".claude/state/active_task_graph.json"

[[ ! -f "$ISSUE_FILE" ]] && exit 0
[[ ! -f "$TASK_GRAPH" ]] && exit 0

ISSUE_NUM=$(cat "$ISSUE_FILE")
COMPLETED_TASK="${COMPLETED_TASK_ID:-}"

[[ -z "$COMPLETED_TASK" ]] && exit 0

# Get current issue body
BODY=$(gh issue view "$ISSUE_NUM" --json body -q '.body')

# Mark checkbox complete: - [ ] T1: → - [x] T1:
UPDATED=$(echo "$BODY" | sed "s/- \[ \] $COMPLETED_TASK:/- [x] $COMPLETED_TASK:/")

# Update issue
gh issue edit "$ISSUE_NUM" --body "$UPDATED"

echo "Marked $COMPLETED_TASK complete in issue #$ISSUE_NUM"
```

### Hook: Auto-Link PRs

```bash
# .claude/hooks/PreToolUse/link-pr-to-issue.sh

TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty')
[[ ! "$COMMAND" =~ "gh pr create" ]] && exit 0

ISSUE_FILE=".claude/state/issue_number"
[[ ! -f "$ISSUE_FILE" ]] && exit 0

ISSUE_NUM=$(cat "$ISSUE_FILE")

# Inject issue reference if not already present
if [[ ! "$COMMAND" =~ "#$ISSUE_NUM" ]]; then
  echo "Remember to link PR to issue #$ISSUE_NUM (add 'Part of #$ISSUE_NUM' to body)"
fi
```

### State Files

```
.claude/state/
├── active_task_graph.json    # Task IDs, agents, waves, deps, status
├── issue_number              # GitHub issue number for this plan
├── current_wave              # Current executing wave (1, 2, ...)
└── completed_tasks           # List of completed task IDs
```

**active_task_graph.json:**
```json
{
  "issue": 42,
  "tasks": [
    {"id": "T1", "desc": "Design auth", "agent": "architecture-tech-lead", "wave": 1, "deps": [], "status": "completed"},
    {"id": "T2", "desc": "User model", "agent": "code-implementer", "wave": 2, "deps": ["T1"], "status": "in_progress"},
    {"id": "T3", "desc": "JWT service", "agent": "code-implementer", "wave": 2, "deps": ["T1"], "status": "pending"}
  ],
  "current_wave": 2
}
```

### Unresolved Questions

- Auto-create issue or require user approval first?
- Wave advancement: strict (block until all wave tasks complete) or flexible (proceed if task's deps met)?
- Issue checkbox update frequency: after each task or batched?
- Handle issue edit conflicts if human also edits?
- Should completed tasks stay in task_graph.json or move to separate file?

---

## References

- [Original repo](https://github.com/barkain/claude-code-workflow-orchestration)
- [Claude Code hooks docs](https://docs.anthropic.com/en/docs/claude-code/hooks)
- [Plugin development guide](https://docs.anthropic.com/en/docs/claude-code/plugins)
