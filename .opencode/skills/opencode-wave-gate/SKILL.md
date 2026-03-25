---
name: opencode-wave-gate
description: "Run after wave implementation complete. Executes test + spec-check + review gate sequence. Usage: /wave-gate"
---

# Wave Gate - Test, Spec & Review Sequence

Executes the gate sequence after all wave tasks are implemented. Verifies test evidence, checks spec alignment, spawns code reviewers, and decides whether to advance.

**Run this after all tasks in a wave are complete.**

---

## Sequence

### Step 1: Verify State

Check the spec directory for the task graph artifact (produced by decompose phase):

```bash
SPEC_DIR=$(ls -td .claude/specs/*/ | head -1)
ls "$SPEC_DIR"
```

Verify the wave's tasks are all marked complete in your tracking. If tracking is done via a task-graph JSON artifact on disk, read it. Otherwise, rely on the orchestrator's knowledge of what was implemented.

### Step 2: Verify Test Evidence

For each task in the current wave, confirm that:
1. Tests were run and passed (look for "BUILD SUCCESS", "X passing", "OK" markers in agent output)
2. New tests were written (not just existing tests re-run)

**How to verify new tests:**
```bash
# Check for new test files or test methods added in this wave
BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "HEAD~10")
git diff --name-only $BASE..HEAD | grep -i test
```

If test evidence is missing for a task, re-spawn the implementation agent for that task. The agent MUST run tests and produce visible pass markers.

### Step 3: Spawn Verification (Parallel)

Spawn **spec-check AND code reviewers** in a single message with multiple Task calls.

**Get wave changes:**
```bash
BASE=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||' || echo "main")
git diff --name-only $BASE...HEAD
```

**Spawn ALL in parallel (single message, multiple Task calls):**

1. **Spec-check invoker** (always, once per wave):
```markdown
## Spec Alignment Check
**Wave:** {wave}
**Tasks:** {task_ids}

Invoke /opencode-spec-check to verify implementation aligns with specification.
Output format required:
- SPEC_CHECK_WAVE: {wave}
- CRITICAL/HIGH/MEDIUM findings
- SPEC_CHECK_CRITICAL_COUNT: N
- SPEC_CHECK_VERDICT: PASSED | BLOCKED
```

2. **Review sub-agents per task** (for each task needing review, spawn ALL in parallel):
   - `code-reviewer` — style, patterns, best practices
   - `silent-failure-hunter` — error handling, silent swallowing
   - `pr-test-analyzer` — test coverage and quality
   - `type-design-analyzer` — type safety and design
   - `comment-analyzer` — comment accuracy and completeness

Each review agent gets the same prompt:
```markdown
## Task: {task_id}
**Description:** {task description}

Files: {comma-separated files relevant to this task}
Task: {task_id}

Review these files and produce a Machine Summary with CRITICAL_COUNT, CRITICAL, and ADVISORY lines.
```

### Step 4: Post GH Comment

After all verification agents complete, post summary:

```bash
gh issue comment {ISSUE} --body "$(cat <<'EOF'
## Wave {N} Verification

### Spec Alignment
**Status:** {PASSED | BLOCKED}
{if blocked: list critical findings}

### Code Review

#### T1: {description}
**Status:** PASSED | BLOCKED - {N} critical, {N} advisory
**Critical:**
- {critical findings list, if any}
**Advisory:**
- {ALL advisory findings - always include, even for PASSED tasks}

#### T2: {description}
...

---
**Wave Status:** PASSED - Ready to advance | BLOCKED - fix issues
EOF
)"
```

**If GH comment fails** (rate limit, auth, network):
- Log summary to `.claude/specs/{date_slug}/wave-{N}-review.md` as fallback
- Proceed with gate logic - don't block on comment failure
- Retry comment post after gate decision

### Step 5: Advance

Verify **five checks** before advancing:
1. **Per-task test evidence** — all wave tasks must have tests passed
2. **New tests written** — all wave tasks must have new tests (unless task is config/migration/docs)
3. **Spec alignment** — spec-check critical count == 0
4. **Per-task review status** — all wave tasks must have been reviewed
5. **No critical findings** — code review critical findings count must be 0

If any check fails, the wave does NOT advance. Fix the issue and re-run `/opencode-wave-gate`.

On success: mark tasks "completed", update GH issue checkboxes if applicable, proceed to next wave.

---

## Re-run After Fixes

When issues fixed, run `/opencode-wave-gate` again. It will:
- Skip test verification if evidence already confirmed
- Re-run spec-check (always runs, overwrites previous)
- Re-review ONLY tasks that were blocked
- Advance when all clear

---

## Handling Failures

### Spec-Check Failures

| Symptom | Cause | Recovery |
|---------|-------|----------|
| No SPEC_CHECK_CRITICAL_COUNT | Output malformed | Re-spawn spec-check-invoker |
| CRITICAL findings | Spec drift detected | Fix drift, re-run /opencode-wave-gate |

### Review Failures

| Symptom | Cause | Recovery |
|---------|-------|----------|
| No output from reviewer | Agent crashed/timed out | Re-spawn that specific reviewer |
| Malformed output | Skill parsing issue | Re-spawn with explicit format reminder |

---

## Constraints

- MUST spawn spec-check AND review agents in parallel (single message)
- MUST use `spec-check-invoker` agent for spec alignment
- MUST spawn review sub-agents directly (`code-reviewer`, `silent-failure-hunter`, `pr-test-analyzer`, `type-design-analyzer`, `comment-analyzer`) per task
- MUST post GH comment before advancing
- NEVER advance if spec-check has critical findings
- NEVER advance if code review has critical findings
