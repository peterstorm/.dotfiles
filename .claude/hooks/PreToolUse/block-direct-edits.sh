#!/bin/bash
# Block direct Edit/Write during active task-planner workflow
# Forces use of Task tool for proper wave validation and parallel execution

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')

# Block Edit and Write tools during active plan
if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" ]]; then
  CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH" 2>/dev/null)
  ISSUE=$(jq -r '.issue // "unknown"' "$TASK_GRAPH" 2>/dev/null)

  echo "BLOCKED: Direct $TOOL_NAME not allowed during task-planner workflow."
  echo ""
  echo "Active plan: Issue #$ISSUE, Wave $CURRENT_WAVE"
  echo ""
  echo "You MUST use the Task tool to spawn agents:"
  echo "  Task(subagent_type=\"code-implementer\", prompt=\"Task ID: T1\\n...\")"
  echo ""
  echo "This ensures:"
  echo "  - Wave order validation"
  echo "  - Parallel execution within waves"
  echo "  - Automatic checkbox updates"
  echo ""
  echo "To bypass (emergency only): rm $TASK_GRAPH"
  exit 2
fi

exit 0
