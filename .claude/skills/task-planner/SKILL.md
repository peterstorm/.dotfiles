---
name: task-planner
version: "1.0.0"
description: "This skill should be used when the user asks to 'plan this', 'orchestrate', 'break down', 'split into phases', 'coordinate tasks', 'create a plan', 'multi-step feature', or has complex tasks needing structured decomposition. Decomposes work into wave-based parallel tasks, assigns specialized agents, creates GitHub Issue for tracking, and manages execution through automated hooks."
tools: [Read, Glob, Grep, Bash, Write, AskUserQuestion, TodoWrite, Skill, Task]
---

# Task Planner - Orchestration Skill

Orchestrates multi-step implementations: decomposition, agent assignment, wave scheduling, GitHub Issue tracking, hook-based execution management.

**This is an ORCHESTRATION skill** - delegates design to `/architecture-tech-lead`, implementation to appropriate agents. Never implement code directly.

---

## Arguments

- `/task-planner "description"` - Start new plan
- `/task-planner --status` - Show current task graph status
- `/task-planner --complete` - Finalize, clean up state
- `/task-planner --abort` - Cancel mid-execution, clean state

---

## Workflow

### 1. Parse Intent

Understand what user wants to achieve:
- What is the goal?
- What are success criteria?
- What codebase areas involved?

### 2. Analyze Complexity

**Simple** (decompose directly):
- Clear scope, <3 tasks
- No architecture decisions needed
- Single feature addition

**Complex** (delegate to arch-lead):
- Multiple components affected
- Architecture decisions required
- Design patterns to choose
- >3 implementation tasks

For complex tasks:
```
Invoke: /architecture-tech-lead
Result: Detailed plan with architecture, code examples, phases
Output: .claude/plans/{YYYY-MM-DD}-{slug}.md
```

### 3. Extract Implementation Tasks

Parse plan into tasks. **Design = the plan itself, NOT a tracked task**. Tasks start at implementation:

```
T1: Create User domain model
T2: Implement JWT service
T3: Add login endpoint
T4: Write tests
```

**Sizing heuristics** - decompose further if:
- Task touches >5 files
- Multiple unrelated concerns in one task
- Description needs "and" to explain

### 4. Assign Agents

Match task keywords to wrapper agents (these preload the corresponding skills):

| Agent (subagent_type) | Triggers |
|-------|----------|
| code-implementer-agent | implement, create, build, add, write code, model |
| architecture-agent | design, architecture, pattern, refactor |
| java-test-agent | test, junit, jqwik, property-based (Java) |
| ts-test-agent | vitest, playwright, react test (TypeScript) |
| security-agent | security, auth, jwt, oauth, vulnerability |
| code-reviewer | review, quality check |
| dotfiles-agent | nix, nixos, home-manager, sops |
| k8s-agent | kubernetes, k8s, kubectl, helm, argocd, deploy, pod, ingress, service, external-secrets, cert-manager, metallb, cloudflared |
| keycloak-agent | keycloak, realm, oidc, abac, authorization services |
| frontend-agent | frontend, ui, react, next.js, component, styling |

Fallback: `general-purpose` (Task tool's built-in agent with all tools) if no keyword match.

### 5. Schedule Waves

Dependency-based wave scheduling:

```
Wave 1: Tasks with no dependencies (run parallel)
Wave 2: Tasks depending on Wave 1
Wave N: Tasks depending on Wave N-1
```

Example:
```
Wave 1: [T1: User model + tests, T2: JWT service + tests]  (parallel)
Wave 2: [T3: Login endpoint + tests]                       (depends on T1, T2)
```

**Note:** Each task includes its own tests (per agent template constraints). Don't create separate "write tests" tasks - tests are part of implementation.

### 6. User Approval

Present plan summary:
- Task breakdown with agents
- Wave schedule
- GitHub Issue will be created

Ask: "Proceed with this plan?"

### 7. Create Artifacts

On approval, create three artifacts:

**A. Local Plan** (already exists from arch-lead or step 2):
```
.claude/plans/{YYYY-MM-DD}-{slug}.md
```

**B. GitHub Issue**:
```bash
gh issue create \
  --title "Plan: {title}" \
  --body "$(cat .claude/plans/{YYYY-MM-DD}-{slug}.md)"
```

Store returned issue number.

**C. State File**: `.claude/state/active_task_graph.json`

See `templates.md` for full schema. Key fields:
- `current_wave`, `executing_tasks`, `tasks[]` (id, status, wave, review_status)
- `wave_gates[N]` (impl_complete, tests_passed, reviews_complete, blocked)

**Status Transitions:**
- `pending` → `in_progress`: Task spawned to agent
- `in_progress` → `implemented`: Agent finished (SubagentStop hook)
- `implemented` → `completed`: Wave gate passed (tests + review ok)

### 8. Orchestrate Execution

For each wave:

1. Get pending tasks in current wave
2. Spawn ALL wave tasks in parallel (single message, multiple Task calls):
   - Update state: add to `executing_tasks`, `status = "in_progress"`
   - Build agent prompt with context (see Agent Context Template)
   - SubagentStop hook: status → "implemented", removes from executing_tasks
3. Wait for all wave tasks to reach "implemented"
4. Run **Wave Gate Sequence** (see 8a) before advancing

### 8a. Wave Gate Sequence

After all wave tasks reach "implemented", the SubagentStop hook outputs:

```
=========================================
  Wave N implementation complete
=========================================

Run: /wave-gate

(Tests + parallel code review + advance)
```

**Invoke `/wave-gate`** - it handles everything:
1. Run integration tests
2. Spawn task-reviewer per task (parallel, uses /review-pr)
3. Aggregate findings (critical blocks, advisory logged)
4. Post GH comment with review summary
5. Advance to next wave (or block if critical findings)

If blocked, fix issues and run `/wave-gate` again - it re-reviews only blocked tasks.

### Helper Scripts

> **Note:** These scripts are called by `/wave-gate` only, not directly by task-planner.

Located in `~/.claude/hooks/helpers/`:

| Script | Purpose |
|--------|---------|
| `mark-tests-passed.sh` | Mark wave tests passed/failed |
| `store-review-findings.sh` | Store critical/advisory per task |
| `complete-wave-gate.sh` | Mark complete, update GH, advance |

---

## Agent Context Template

See `templates.md` for full template. Key elements:
- `**Task ID:** TX` (required for hooks to track)
- Task description + relevant plan context
- Constraints: follow plan, write tests, tests must pass

---

## State Management

### On `/task-planner "description"`:
1. Create `.claude/state/active_task_graph.json`
2. Hooks become active (they check for this file)

### On `/task-planner --status`:
Read state file and display formatted summary:
```
Plan: Issue #42 - Add user authentication
Wave 2/3 | 2 completed, 1 in progress, 1 pending

[✓] T1: Create User model (code-implementer)
[✓] T2: JWT service (code-implementer)
[→] T3: Login endpoint (code-implementer)
[ ] T4: Tests (java-test-agent)
```

### On `/task-planner --complete`:
1. Verify all tasks completed
2. Optionally close GitHub Issue
3. Remove `.claude/state/active_task_graph.json`
4. Hooks deactivate

### On `/task-planner --abort`:
1. Ask: close issue or leave open?
2. Remove `.claude/state/active_task_graph.json`
3. Hooks deactivate

### Modifying Plan Mid-Execution

To add/remove/modify tasks:
1. Edit `active_task_graph.json` - add task to `tasks[]`, set correct `wave`
2. Update GH Issue - add/edit checkbox line matching task ID
3. If adding to current wave, task runs in next spawn cycle

Cannot modify tasks already `in_progress` or `completed`.

---

## GitHub Issue Format

See `templates.md` for full format. Key requirements:
- Checkbox tasks: `- [ ] T1: description` (hooks update these)
- Wave groupings with dependencies noted
- Execution order table

---

## Hook Integration

Hooks auto-activate when `active_task_graph.json` exists:

| Hook | Purpose |
|------|---------|
| `block-direct-edits.sh` | BLOCKS Edit/Write - forces Task tool |
| `validate-task-execution.sh` | Validates wave order + review gate |
| `update-task-status.sh` | Marks "implemented", prompts /wave-gate |

---

## Error Recovery

| Failure | Recovery |
|---------|----------|
| Agent crashes mid-task | Re-spawn same task; state shows `in_progress` |
| GH issue create fails | Retry `gh issue create`; continue without if persistent |
| State file corrupted | Rebuild from GH issue checkboxes + local plan file |
| Wave gate blocked | Fix issues, run `/wave-gate` again (re-reviews blocked only) |
| Tests fail repeatedly | Ask user: fix tests, skip task, or abort plan |

---

## Constraints

- **NEVER use Edit/Write directly** - blocked by `block-direct-edits.sh` hook
- **MUST use Task tool** to spawn agents for ALL implementation work
- Delegate design to /architecture-tech-lead for complex tasks
- Must get user approval before creating issue
- Must populate TodoWrite with task breakdown
- Task IDs must match `- [ ] T1:` format in issue for checkbox updates

---

## CRITICAL: Parallel Execution

**Multiple Task calls in ONE message** = parallel execution within wave.

Each Task call needs: subagent_type, description, prompt with `**Task ID:** TX`
