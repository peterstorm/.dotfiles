# Task Planner Templates

Reference templates for task-planner skill. Load on demand, not part of core workflow.

## Agent Context Template

When spawning impl agents, use this format:

```markdown
## Task Assignment

**Task ID:** T2
**Wave:** 1
**Agent:** code-implementer-agent
**Dependencies:** None

## Your Task

{task description}

## Context from Plan

> **Architecture Decision:**
> {relevant section from plan}

> **Files to Create/Modify:**
> {file list}

## Full Plan

Available at: {plan_file path from state}

## Constraints

- Follow patterns in plan
- Do not modify scope
- MUST write NEW tests for your implementation — rerunning existing tests is NOT sufficient
- MUST run tests and ensure they pass before completing
- Task is NOT complete until tests pass
- Test output must contain recognizable pass markers (e.g., "BUILD SUCCESS", "X passing")
  so the SubagentStop hook can extract test evidence from your transcript
- A SubagentStop hook will git-diff for new test method patterns (@Test, it(, test(, describe()
- If no new test patterns found in your diff, wave advancement is BLOCKED
```

## GitHub Issue Format

Issue body structure with checkbox tasks:

```markdown
## Plan: {title}

### Context & Analysis
{codebase exploration findings}

### Architecture Decisions
{design choices with rationale}

### Task Breakdown

#### Wave 1: {description} (parallel)
- [ ] T1: {task description}
- [ ] T2: {task description}

#### Wave 2: {description} (depends on Wave 1)
- [ ] T3: {task description}

### Execution Order

| ID | Task | Agent | Wave | Depends |
|----|------|-------|------|---------|
| T1 | ... | code-implementer-agent | 1 | - |

### Verification Checklist
- [ ] All tests pass
- [ ] No security vulnerabilities
- [ ] Code reviewed

### Related PRs
<!-- Auto-updated by hooks -->
```

## State File Schema

```json
{
  "plan_title": "Feature name",
  "plan_file": ".claude/plans/YYYY-MM-DD-slug.md",
  "github_issue": 42,
  "github_repo": "org/repo",
  "created_at": "2025-01-23T10:00:00Z",
  "updated_at": "2025-01-23T12:30:00Z",
  "current_wave": 1,
  "total_waves": 2,
  "executing_tasks": [],
  "tasks": [{
    "id": "T1",
    "description": "...",
    "agent": "code-implementer-agent",
    "wave": 1,
    "depends_on": [],
    "status": "pending|in_progress|implemented|completed",
    "start_sha": "abc1234",
    "tests_passed": true,
    "test_evidence": "maven: Tests run: 15, Failures: 0, Errors: 0",
    "new_tests_required": true,
    "new_tests_written": true,
    "new_test_evidence": "3 new test methods (java: 3 new @Test/@Property methods)",
    "files_modified": ["src/main/java/Foo.java", "src/test/java/FooTest.java"],
    "review_status": "pending|passed|blocked",
    "critical_findings": [],
    "advisory_findings": []
  }],
  "wave_gates": {
    "1": {
      "impl_complete": false,
      "tests_passed": null,
      "reviews_complete": false,
      "blocked": false
    }
  }
}
```

### Per-Task Fields Set by Hooks

These fields are set **automatically** by SubagentStop hooks. They cannot be set manually (guard hook blocks state file writes via Bash).

| Field | Set By | When |
|-------|--------|------|
| `start_sha` | `validate-task-execution.sh` | PreToolUse: HEAD SHA stored before task agent spawns |
| `status` → "implemented" | `update-task-status.sh` | Implementation agent completes |
| `tests_passed` | `update-task-status.sh` | Extracted from agent transcript (Maven/Node/Vitest/pytest markers) |
| `test_evidence` | `update-task-status.sh` | Description of which markers were found |
| `files_modified` | `update-task-status.sh` | Files touched by agent (from Write/Edit tool calls in transcript) |
| `new_tests_written` | `verify-new-tests.sh` | Git diff scanned for new test method patterns (scoped to files_modified) |
| `new_test_evidence` | `verify-new-tests.sh` | Count and details of new test methods found |
| `review_status` | `store-review-findings.sh` helper (called by SubagentStop hook) | Review agent completes |
| `critical_findings` | `store-review-findings.sh` helper | Parsed from reviewer output |
| `advisory_findings` | `store-review-findings.sh` helper | Parsed from reviewer output |

### Task Definition Fields (set during planning)

| Field | Default | Description |
|-------|---------|-------------|
| `new_tests_required` | `true` | Set to `false` for migrations, configs, renames. Auto-detected from keywords. |

### Wave Gate Checks (by `complete-wave-gate.sh`)

All four must pass before wave advances:

1. **Test evidence**: ALL wave tasks have `tests_passed == true`
2. **New tests written**: ALL wave tasks satisfy `!new_tests_required || new_tests_written`
3. **Review status**: ALL wave tasks have `review_status != "pending"`
4. **No critical findings**: `critical_findings` count is 0 across all wave tasks
