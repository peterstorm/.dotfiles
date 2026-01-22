---
name: task-planner
version: "1.0.0"
description: "Use when: multi-step tasks, 'plan this', 'orchestrate', 'break down', complex features needing wave-based execution. Decomposes tasks, assigns agents, creates GitHub Issue for tracking, manages wave-based execution with hooks."
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

### 4. Assign Agents

Match task keywords to available agents:

| Agent | Triggers |
|-------|----------|
| code-implementer | implement, create, build, add, write code, model |
| architecture-tech-lead | design, architecture, pattern, refactor |
| java-test-engineer | test, junit, jqwik, property-based (Java) |
| ts-test-engineer | vitest, playwright, react test (TypeScript) |
| security-expert | security, auth, jwt, oauth, vulnerability |
| code-reviewer | review, quality check |
| dotfiles-expert | nix, nixos, home-manager, sops |

Fallback: `general-purpose` if no match.

### 5. Schedule Waves

Dependency-based wave scheduling:

```
Wave 1: Tasks with no dependencies (run parallel)
Wave 2: Tasks depending on Wave 1
Wave N: Tasks depending on Wave N-1
```

Example:
```
Wave 1: [T1: model, T2: service]     (parallel)
Wave 2: [T3: endpoint]               (depends on T1, T2)
Wave 3: [T4: tests]                  (depends on T3)
```

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
  --body "$(cat .claude/plans/{slug}.md)"
```

Store returned issue number.

**C. State File**:
```json
// .claude/state/active_task_graph.json
{
  "plan_file": ".claude/plans/2026-01-22-user-auth.md",
  "issue": 42,
  "current_wave": 1,
  "executing_task": null,
  "tasks": [
    {
      "id": "T1",
      "description": "Create User domain model",
      "agent": "code-implementer",
      "wave": 1,
      "depends_on": [],
      "status": "pending"
    }
  ]
}
```

### 8. Orchestrate Execution

For each wave:

1. Get pending tasks in current wave
2. For each task:
   - Update state: `executing_task = "T1"`, `status = "in_progress"`
   - Build agent prompt with context (see Agent Context Template)
   - Spawn agent via Task tool
   - SubagentStop hook auto-updates: status → completed, checkbox marked
3. Wait for all wave tasks
4. Advance to next wave (strict: ALL must complete)

---

## Agent Context Template

When spawning agents, include:

```markdown
## Task Assignment

**Task ID:** T2
**Wave:** 1
**Agent:** code-implementer
**Dependencies:** None

## Your Task

Implement JWT token service (sign/verify/refresh)

## Context from Plan

> **Architecture Decision:**
> [Relevant section extracted from plan]

> **Files to Create/Modify:**
> - src/auth/JwtTokenService.java

## Full Plan

Available at: `.claude/plans/2026-01-22-user-auth.md`

## Constraints

- Follow patterns in plan
- Do not modify scope
- Mark complete when implementation + tests pass
```

---

## State Management

### On `/task-planner "description"`:
1. Create `.claude/state/active_task_graph.json`
2. Hooks become active (they check for this file)

### On `/task-planner --status`:
```bash
cat .claude/state/active_task_graph.json | jq
```
Show: current wave, completed tasks, pending tasks.

### On `/task-planner --complete`:
1. Verify all tasks completed
2. Optionally close GitHub Issue
3. Remove `.claude/state/active_task_graph.json`
4. Hooks deactivate

### On `/task-planner --abort`:
1. Ask: close issue or leave open?
2. Remove `.claude/state/active_task_graph.json`
3. Hooks deactivate

---

## GitHub Issue Format

Issue body = full plan content with checkbox tasks:

```markdown
## Plan: User Authentication

### Context & Analysis
[Codebase exploration findings]

### Architecture Decisions
[Design choices with rationale, code examples]

### Task Breakdown

#### Wave 1: Core Components (parallel)
- [ ] T1: Create User domain model with password hash
- [ ] T2: Implement JWT token service

#### Wave 2: Integration (depends on Wave 1)
- [ ] T3: Add login/register endpoints

#### Wave 3: Quality (depends on Wave 2)
- [ ] T4: Write property tests for auth flow

### Execution Order

| ID | Task | Agent | Wave | Depends |
|----|------|-------|------|---------|
| T1 | User model | code-implementer | 1 | - |
| T2 | JWT service | code-implementer | 1 | - |
| T3 | Endpoints | code-implementer | 2 | T1, T2 |
| T4 | Tests | java-test-engineer | 3 | T3 |

### Verification Checklist
- [ ] All tests pass
- [ ] No security vulnerabilities
- [ ] Code reviewed

### Related PRs
<!-- Auto-updated by hooks -->
```

---

## Hook Integration

Hooks auto-activate when `active_task_graph.json` exists:

**PreToolUse/validate-wave.sh**: Blocks out-of-order task execution
**PreToolUse/link-pr-to-issue.sh**: Reminds to link PRs
**SubagentStop/update-task-status.sh**: Marks checkboxes, advances waves

---

## Constraints

- Never implement code directly
- Delegate design to /architecture-tech-lead for complex tasks
- Must get user approval before creating issue
- Must populate TodoWrite with task breakdown
- Task IDs must match `- [ ] T1:` format in issue for checkbox updates
