#!/bin/bash
# Mark subagent as active so PreToolUse can allow Edit/Write from subagents
# Also stores agent_type for SubagentStop hooks to read
# Also stores task_graph absolute path for cross-repo access
INPUT=$(cat)

# DEBUG: Log raw input
echo "$(date '+%Y-%m-%d %H:%M:%S') SubagentStart INPUT: $INPUT" >> /tmp/claude-hooks-debug.log

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# DEBUG: Log parsed values
echo "$(date '+%Y-%m-%d %H:%M:%S') SubagentStart PARSED: session=$SESSION_ID agent=$AGENT_ID type=$AGENT_TYPE" >> /tmp/claude-hooks-debug.log

# Create session tracking directory (restrictive permissions)
umask 077
mkdir -p /tmp/claude-subagents

# Track active agents for cleanup purposes (optional, not critical)
if [[ -n "$AGENT_ID" ]]; then
  echo "$AGENT_ID" >> "/tmp/claude-subagents/${SESSION_ID}.active"
fi
# NOTE: agent_type no longer stored in temp file - SubagentStop reads it from JSON input

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
