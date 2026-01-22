#!/bin/bash
# Validate wave order for task-planner workflow
# Only active when task graph exists

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Only check Task tool calls
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Task" ]] && exit 0

# Extract task ID from prompt (expects "Task ID: T1" pattern)
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.prompt // empty')
TASK_ID=$(echo "$PROMPT" | grep -oE 'Task ID: (T[0-9]+)' | head -1 | cut -d' ' -f3)
[[ -z "$TASK_ID" ]] && exit 0  # Not a planned task, allow

# Validate wave order
CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
TASK_WAVE=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .wave" "$TASK_GRAPH")

[[ -z "$TASK_WAVE" ]] && exit 0  # Task not in graph, allow

[[ "$TASK_WAVE" -gt "$CURRENT_WAVE" ]] && {
  echo "Cannot execute $TASK_ID (wave $TASK_WAVE) - current wave is $CURRENT_WAVE"
  echo "Complete all wave $CURRENT_WAVE tasks first."
  exit 2
}

# Check dependencies complete
DEPS=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .depends_on[]?" "$TASK_GRAPH")
for dep in $DEPS; do
  STATUS=$(jq -r ".tasks[] | select(.id==\"$dep\") | .status" "$TASK_GRAPH")
  [[ "$STATUS" != "completed" ]] && {
    echo "Cannot execute $TASK_ID - dependency $dep not complete (status: $STATUS)"
    exit 2
  }
done

exit 0
