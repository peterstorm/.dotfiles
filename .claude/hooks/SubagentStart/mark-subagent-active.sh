#!/bin/bash
# Mark subagent as active so PreToolUse can allow Edit/Write from subagents
# Also stores agent_type for SubagentStop hooks to read
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

exit 0
