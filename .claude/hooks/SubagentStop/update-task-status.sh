#!/bin/bash
# Update task status when impl agent completes
# Marks task "implemented" (not "completed" - that happens after review gate)
# Only active when task graph exists

TASK_GRAPH=".claude/state/active_task_graph.json"
LOCK_FILE=".claude/state/.task_graph.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Extract task ID from agent's prompt (handles parallel execution correctly)
# Try multiple HOOK_INPUT fields that might contain the prompt
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.transcript // .prompt // .tool_input.prompt // empty' 2>/dev/null)

# Match "Task ID: T1" or "**Task ID:** T1" (markdown bold)
TASK_ID=$(echo "$PROMPT" | grep -oE '(\*\*)?Task ID:(\*\*)? ?(T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')

[[ -z "$TASK_ID" ]] && exit 0  # Not a tracked task, ignore

# Use cross-platform file locking
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

# Verify task exists and isn't already completed
TASK_STATUS=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .status" "$TASK_GRAPH")
[[ -z "$TASK_STATUS" || "$TASK_STATUS" == "completed" || "$TASK_STATUS" == "implemented" ]] && exit 0

# Mark task as "implemented", remove from executing_tasks
jq "
  .tasks |= map(if .id == \"$TASK_ID\" then .status = \"implemented\" else . end) |
  .executing_tasks |= (. // [] | map(select(. != \"$TASK_ID\"))) |
  .executing_task = null
" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Task $TASK_ID implemented."

# Check if all wave tasks are now "implemented" or "completed"
CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
NOT_IMPL=$(jq -r "[.tasks[] | select(.wave == $CURRENT_WAVE and .status != \"implemented\" and .status != \"completed\")] | length" "$TASK_GRAPH")

if [[ "$NOT_IMPL" -eq 0 ]]; then
  # Mark wave impl_complete
  jq ".wave_gates[\"$CURRENT_WAVE\"].impl_complete = true" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

  echo ""
  echo "========================================="
  echo "  Wave $CURRENT_WAVE implementation complete"
  echo "========================================="
  echo ""
  echo "Run: /wave-gate"
  echo ""
  echo "(Tests + parallel code review + advance)"
fi

# Lock released automatically when script exits
exit 0
