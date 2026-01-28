#!/bin/bash
# Mark subagent as active so PreToolUse can allow Edit/Write from subagents
# Also stores agent_type for SubagentStop hooks to read
# Also stores task_graph absolute path for cross-repo access
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# Create flag file for this session (restrictive permissions)
umask 077
mkdir -p /tmp/claude-subagents
if [[ -n "$AGENT_ID" ]]; then
  echo "$AGENT_ID" >> "/tmp/claude-subagents/${SESSION_ID}.active"
  # Store agent type for SubagentStop hooks
  if [[ -n "$AGENT_TYPE" ]]; then
    echo "$AGENT_TYPE" > "/tmp/claude-subagents/${AGENT_ID}.type"
  fi
fi

# Store task graph absolute path for cross-repo access
# SubagentStart runs in orchestrator's cwd where task graph exists
# SubagentStop may run in different repo, needs this path to find task graph
TASK_GRAPH=".claude/state/active_task_graph.json"
TASK_GRAPH_FILE="/tmp/claude-subagents/${SESSION_ID}.task_graph"
if [[ -f "$TASK_GRAPH" && ! -f "$TASK_GRAPH_FILE" ]]; then
  ABS_TASK_GRAPH="$(cd "$(dirname "$TASK_GRAPH")" && pwd)/$(basename "$TASK_GRAPH")"
  echo "$ABS_TASK_GRAPH" > "$TASK_GRAPH_FILE"
fi

exit 0
