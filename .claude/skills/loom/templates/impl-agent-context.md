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

## CRITICAL: You CAN Write Files

**You are a subagent. PreToolUse hooks DO NOT apply to subagents (they bypass hooks entirely).**
- You MUST use Write/Edit tools to create/modify files — this WILL work
- Do NOT read `.claude/hooks/` or `.claude/state/` files — they are irrelevant to you
- Do NOT check if you are "allowed" to write — you are. Just write.

## Constraints

- Follow patterns defined in plan
- Do not modify scope beyond this task
- MUST satisfy spec anchors listed above

## CRITICAL: Test Execution Required

**You MUST run the project's test suite before completing this task.**

1. Run the appropriate test command for this project (e.g., `mvn test`, `npm test`, `pytest`, etc.)
2. Include the FULL test output in your response
3. Tests MUST pass - if they fail, fix the issues and re-run
4. Your task is NOT complete until tests pass and output is shown

The SubagentStop hook extracts test evidence from your output to update the task graph.
Without visible test output showing pass markers (e.g., "BUILD SUCCESS", "X passing", "OK"),
the task will NOT be marked as having tests passed.

## New Tests Required

- You MUST write NEW tests for your implementation
- Rerunning existing tests alone is NOT sufficient
- A hook will git-diff for new test patterns (@Test, it(, test(, describe()
- If no new test patterns found, wave advancement is BLOCKED
