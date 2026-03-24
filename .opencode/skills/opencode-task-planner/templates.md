# Task Planner Templates

Reference templates for task-planner skill. Load on demand, not part of core workflow.

## Template Files

Phase and agent context templates are in `templates/` directory:

| File | Purpose |
|------|---------|
| `templates/phase-brainstorm.md` | Artifact format guide for orchestrator-driven brainstorm |
| `templates/phase-specify.md` | Context for specify-agent |
| `templates/phase-clarify.md` | Orchestrator guide for interactive clarify phase |
| `templates/phase-architecture.md` | Context for architecture-agent |
| `templates/phase-plan-alignment.md` | Context for plan-alignment-agent |
| `templates/phase-decompose.md` | Context for decompose-agent |
| `templates/impl-agent-context.md` | Context for implementation agents |

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
<!-- Updated manually -->
```

## Task Graph Schema

The task graph is saved to `.claude/specs/{slug}/task-graph.json` during the decompose phase:

```json
{
  "plan_title": "Feature name",
  "plan_file": ".claude/plans/YYYY-MM-DD-slug.md",
  "spec_file": ".claude/specs/YYYY-MM-DD-slug/spec.md",
  "github_issue": 42,
  "total_waves": 2,
  "tasks": [{
    "id": "T1",
    "description": "...",
    "agent": "code-implementer-agent",
    "wave": 1,
    "depends_on": [],
    "spec_anchors": ["FR-003", "SC-002", "US1.acceptance[2]"],
    "status": "pending",
    "new_tests_required": true,
    "files": ["src/main/java/Foo.java", "src/test/java/FooTest.java"]
  }]
}
```

### Task Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Unique task ID (T1, T2, ...) |
| `description` | yes | What the task does |
| `agent` | yes | Agent type to spawn (e.g. `code-implementer-agent`) |
| `wave` | yes | Execution wave (1-based) |
| `depends_on` | yes | Task IDs that must complete first |
| `spec_anchors` | yes | Requirement IDs this task satisfies (FR-xxx, SC-xxx, US-x.acceptance[N]) |
| `status` | yes | Current status: pending, in_progress, implemented, completed |
| `new_tests_required` | no | Default `true`. Set `false` for migrations, configs, renames. |
| `files` | no | Files to create/modify |

### Wave Gate Checks

All must pass before advancing to the next wave:

1. **Tests pass**: All wave tasks produce passing test evidence
2. **New tests written**: Tasks with `new_tests_required: true` include new tests
3. **Spec alignment**: spec-check finds no critical drift
4. **Code reviewed**: review agent finds no critical findings
