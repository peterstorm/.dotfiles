---
name: opencode-spec-check
description: "This skill should be used when the user asks to 'check spec alignment', 'verify requirements coverage', 'detect drift', 'spec audit', or automatically at wave gates. Verifies implementation aligns with specification - different from code review which checks quality."
---

# Spec-Check - Drift Detection

Read-only verification that implementation aligns with specification. Detects coverage gaps, scope creep, and requirement drift.

**When to run:**
- At wave gates (integrated into `/opencode-wave-gate` sequence)
- Before `/finalize`
- On-demand during long implementations
- Manual: `/opencode-spec-check`

**Not what this does:** Check code quality, style, security (that's code-reviewer's job).

---

## Integration with Wave-Gate

Spec-check runs as part of wave-gate sequence, between test verification and code review:

```
Wave N complete
    -> verify test evidence
    -> /opencode-spec-check
    -> spawn code reviewers
    -> advance wave
```

CRITICAL findings from spec-check block wave advancement.

---

## Process

### 1. Load Artifacts

```bash
# Find spec
SPEC=$(ls -t .claude/specs/*/spec.md | head -1)

# Find plan (look for architecture.md or plan.md in the spec dir)
SPEC_DIR=$(dirname "$SPEC")
PLAN=$(ls "$SPEC_DIR"/architecture.md "$SPEC_DIR"/plan.md 2>/dev/null | head -1)
```

If a task graph JSON artifact exists on disk (from decompose phase), read it for wave/task info:
```bash
ls "$SPEC_DIR"/task-graph.json 2>/dev/null
```

### 2. Build Requirement Map

Extract from spec:
- FR-xxx (Functional Requirements)
- SC-xxx (Success Criteria)
- US-x acceptance scenarios

Build mapping:
```
FR-001 -> {description, priority, related_scenarios}
FR-002 -> {description, priority, related_scenarios}
SC-001 -> {metric, threshold}
...
```

### 3. Build Implementation Map

From wave tasks and git diff:
```bash
# Files changed in current wave
BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "HEAD~10")
git diff --name-only $BASE..HEAD
```

Extract from code:
- Functions/classes created
- Tests written
- API endpoints added

### 4. Run Detection Passes

#### Pass 1: Coverage Gaps

Check every FR/SC has corresponding implementation:

| Finding | Severity |
|---------|----------|
| P1 requirement with no code | CRITICAL |
| P2 requirement with no code | HIGH |
| P3 requirement with no code | MEDIUM |
| Success criteria with no test | HIGH |
| Acceptance scenario with no test | MEDIUM |

**Detection method:**
- Parse task descriptions for requirement references (FR-xxx, SC-xxx)
- Search code for requirement IDs in comments
- Match test names to acceptance scenarios

#### Pass 2: Scope Creep

Check for code that maps to no requirement:

| Finding | Severity |
|---------|----------|
| New feature not in spec | CRITICAL |
| New endpoint not in spec | HIGH |
| New entity not in spec | HIGH |
| Extra configuration | MEDIUM |

**Detection method:**
- Compare created functions/endpoints to spec
- Check Out of Scope section for violations
- Flag code with no traceability to requirements

#### Pass 3: Terminology Drift

Check naming consistency:

| Finding | Severity |
|---------|----------|
| Spec says "Order", code says "Purchase" | MEDIUM |
| Spec says "User", code says "Customer" | MEDIUM |
| Inconsistent naming across files | LOW |

**Detection method:**
- Extract key terms from spec (entities, actions)
- Search codebase for variants
- Flag mismatches

#### Pass 4: Acceptance Criteria Coverage

For each Given/When/Then in spec:

| Finding | Severity |
|---------|----------|
| Happy path scenario with no test | HIGH |
| Error scenario with no test | MEDIUM |
| Edge case scenario with no test | LOW |

**Detection method:**
- Parse acceptance scenarios from spec
- Match to test descriptions/names
- Check test assertions align with "Then" clauses

#### Pass 5: Success Criteria Verifiability

For each SC-xxx:

| Finding | Severity |
|---------|----------|
| Metric claimed but no measurement | HIGH |
| Threshold exists but not tested | MEDIUM |
| SC marked complete but no evidence | CRITICAL |

**Detection method:**
- Check for performance tests
- Check for metric assertions
- Validate evidence in test output

---

## Output Format

### Console Output

```
## Spec-Check Report

**Spec:** .claude/specs/2025-01-29-user-auth/spec.md
**Wave:** 2
**Tasks Checked:** T3, T4, T5

### CRITICAL (2)

1. **Coverage Gap:** FR-003 (email validation) has no implementation
   - Requirement: "System MUST validate email format"
   - Expected in: T3 (auth service)
   - Found: No validation logic in auth service

2. **Scope Creep:** New /api/admin endpoint not in spec
   - File: src/routes/admin.ts
   - Not mapped to any FR-xxx
   - Not in Out of Scope (should be if intentional)

### HIGH (1)

1. **Acceptance Gap:** US1 error scenario has no test
   - Scenario: "Given invalid password, When submit, Then error shown"
   - Expected test: Login failure test
   - Found: Only happy path tested

### MEDIUM (2)

1. **Terminology Drift:** Spec "User" vs Code "Account"
2. **Missing Metric:** SC-002 (response time) not measured in tests

### Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| HIGH | 1 |
| MEDIUM | 2 |
| LOW | 0 |

**Verdict:** BLOCKED - 2 critical findings must be resolved
```

### Artifact on Disk

Write the spec-check results to the spec directory:

```bash
SPEC_DIR=$(dirname "$SPEC")
# Write to: $SPEC_DIR/spec-check-wave-N.md
```

---

## Wave-Gate Integration

### Blocking Logic

Wave advancement blocked if:
- Any CRITICAL findings exist

Wave advancement proceeds if:
- Zero CRITICAL findings (HIGH/MEDIUM are advisory)

### Re-Check After Fixes

When critical issues fixed:
1. Re-run `/opencode-spec-check`
2. Updated findings replace previous
3. If zero CRITICAL findings, wave can advance

---

## Severity Definitions

| Severity | Meaning | Blocks Wave? |
|----------|---------|--------------|
| CRITICAL | Spec violation, missing P1 requirement, scope creep | Yes |
| HIGH | Missing test coverage, P2 gaps | No (advisory) |
| MEDIUM | Terminology drift, P3 gaps | No (advisory) |
| LOW | Minor inconsistencies | No (informational) |

---

## Manual Invocation

```bash
/opencode-spec-check                    # Check current wave
/opencode-spec-check --full             # Check all waves
/opencode-spec-check --spec path/to/spec.md  # Use specific spec
```

---

## Fixing Critical Findings

### Coverage Gap

```markdown
**Finding:** FR-003 has no implementation

**Fix options:**
1. Implement the requirement (spawn impl agent for affected task)
2. Defer requirement (move to Out of Scope with justification)
3. Update spec if requirement changed (requires re-approval)
```

### Scope Creep

```markdown
**Finding:** New endpoint not in spec

**Fix options:**
1. Add requirement to spec (FR-xxx) and re-run /opencode-specify
2. Remove code if truly out of scope
3. Document in Out of Scope as "added during implementation" with rationale
```

---

## Constraints

- Read-only: NEVER modify code or spec
- Findings only: Report issues, don't fix them
- Spec is source of truth: Code must align to spec, not vice versa
- CRITICAL blocks waves: Non-negotiable
- Different from code review: Quality vs alignment are separate concerns
