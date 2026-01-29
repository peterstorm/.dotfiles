# Implementation Agent Context

Template for spawning implementation agents during Execute phase. Variables in `{braces}` must be substituted.

---

## Task Assignment

**Task ID:** {task_id}
**Wave:** {wave}
**Agent:** {agent_type}
**Dependencies:** {dependencies}

## Your Task

{task_description}

## Spec Anchors (MUST satisfy)

{spec_anchors_formatted}

These are from the specification - your implementation MUST satisfy these requirements.
Spec-check at wave gate will verify alignment.

## Context from Plan

{plan_context}

## Files to Create/Modify

{file_list}

## Full Plan

Available at: {plan_file_path}

## Constraints

- Follow patterns defined in plan
- Do not modify scope beyond this task
- MUST satisfy spec anchors listed above
- MUST write NEW tests for your implementation - rerunning existing tests is NOT sufficient
- MUST run tests and ensure they pass before completing
- Task is NOT complete until tests pass
- Test output must contain recognizable pass markers (e.g., "BUILD SUCCESS", "X passing")
  so the SubagentStop hook can extract test evidence from your transcript
- A SubagentStop hook will git-diff for new test method patterns (@Test, it(, test(, describe()
- If no new test patterns found in your diff, wave advancement is BLOCKED
