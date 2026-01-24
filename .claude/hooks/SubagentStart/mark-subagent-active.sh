#!/bin/bash
# Mark subagent as active so PreToolUse can allow Edit/Write from subagents
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')

# Create flag file for this session
mkdir -p /tmp/claude-subagents
if [[ -n "$AGENT_ID" ]]; then
  echo "$AGENT_ID" >> "/tmp/claude-subagents/${SESSION_ID}.active"
fi

exit 0
