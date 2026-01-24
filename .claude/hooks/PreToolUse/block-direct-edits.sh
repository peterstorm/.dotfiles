#!/bin/bash
# Block direct Edit/Write during active task-planner workflow
# EXCEPT when called from a subagent (detected via SubagentStart flag)
#
# NOTE: Exit code 2 requires stderr output, NOT stdout!
# NOTE: Hook input comes via stdin!

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')

# Check if there's an active subagent for this session - if so, allow Edit/Write
SUBAGENT_FILE="/tmp/claude-subagents/${SESSION_ID}.active"
if [[ -f "$SUBAGENT_FILE" ]]; then
  # Subagent is active, allow Edit/Write
  exit 0
fi

CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH" 2>/dev/null)
ISSUE=$(jq -r '.issue_number // .issue // "unknown"' "$TASK_GRAPH" 2>/dev/null)

# Check if wave is blocked due to critical review findings
WAVE_BLOCKED=$(jq -r ".wave_gates[\"$CURRENT_WAVE\"].blocked // false" "$TASK_GRAPH" 2>/dev/null)

if [[ "$WAVE_BLOCKED" == "true" ]]; then
  if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
    BLOCKED_TASKS=$(jq -r ".tasks[] | select(.wave == $CURRENT_WAVE and .review_status == \"blocked\") | .id" "$TASK_GRAPH" | tr '\n' ', ' | sed 's/,$//')
    echo "BLOCKED: Wave $CURRENT_WAVE has critical review findings." >&2
    echo "" >&2
    echo "Blocked tasks: $BLOCKED_TASKS" >&2
    echo "" >&2
    echo "To proceed:" >&2
    echo "  1. Fix the critical issues listed in the review" >&2
    echo "  2. Run /wave-gate to re-review" >&2
    echo "" >&2
    echo "Issue: #$ISSUE" >&2
    exit 2
  fi
fi

# Block Edit and Write tools during active plan (must use Task tool)
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
  echo "BLOCKED: Direct $TOOL_NAME not allowed during task-planner workflow." >&2
  echo "" >&2
  echo "Active plan: Issue #$ISSUE, Wave $CURRENT_WAVE" >&2
  echo "" >&2
  echo "You MUST use the Task tool to spawn agents." >&2
  echo "" >&2
  echo "To bypass (emergency only): rm $TASK_GRAPH" >&2
  exit 2
fi

exit 0
