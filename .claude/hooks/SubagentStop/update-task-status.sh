#!/bin/bash
# Update task status + GitHub Issue checkbox when agent completes
# Only active when task graph exists

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Get currently executing task from state file
TASK_ID=$(jq -r '.executing_task // empty' "$TASK_GRAPH")
[[ -z "$TASK_ID" || "$TASK_ID" == "null" ]] && exit 0

# Update task status to completed, clear executing_task
jq "
  .tasks |= map(if .id == \"$TASK_ID\" then .status = \"completed\" else . end) |
  .executing_task = null
" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Task $TASK_ID completed."

# Update GitHub Issue checkbox
ISSUE=$(jq -r '.issue // empty' "$TASK_GRAPH")
if [[ -n "$ISSUE" && "$ISSUE" != "null" ]]; then
  BODY=$(gh issue view "$ISSUE" --json body -q '.body' 2>/dev/null)
  if [[ -n "$BODY" ]]; then
    UPDATED=$(echo "$BODY" | sed "s/- \[ \] $TASK_ID:/- [x] $TASK_ID:/")
    gh issue edit "$ISSUE" --body "$UPDATED" 2>/dev/null && \
      echo "Marked $TASK_ID complete in issue #$ISSUE"
  fi
fi

# Check if wave complete → advance (strict mode)
CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
INCOMPLETE=$(jq -r "[.tasks[] | select(.wave == $CURRENT_WAVE and .status != \"completed\")] | length" "$TASK_GRAPH")

if [[ "$INCOMPLETE" -eq 0 ]]; then
  MAX_WAVE=$(jq -r '[.tasks[].wave] | max' "$TASK_GRAPH")
  NEXT_WAVE=$((CURRENT_WAVE + 1))

  if [[ "$NEXT_WAVE" -le "$MAX_WAVE" ]]; then
    jq ".current_wave = $NEXT_WAVE" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"
    echo "Wave $CURRENT_WAVE complete. Advanced to wave $NEXT_WAVE."
  else
    echo "All waves complete! Run /task-planner --complete to finalize."
  fi
fi

exit 0
