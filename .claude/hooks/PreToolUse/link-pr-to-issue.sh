#!/bin/bash
# Remind to link PRs to active plan issue
# Only active when task graph exists

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Only check Bash tool calls
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

# Check if command is gh pr create
COMMAND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty')
[[ ! "$COMMAND" =~ "gh pr create" ]] && exit 0

# Get issue number from task graph
ISSUE=$(jq -r '.issue // empty' "$TASK_GRAPH")
[[ -z "$ISSUE" ]] && exit 0

# Remind if issue not referenced
if [[ ! "$COMMAND" =~ "#$ISSUE" ]]; then
  echo "Tip: Link PR to plan issue with 'Part of #$ISSUE' in body"
fi

exit 0
