#!/bin/bash
# Clean up subagent flag file when subagent completes
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')

# Remove this agent from active list
SUBAGENT_FILE="/tmp/claude-subagents/${SESSION_ID}.active"
if [[ -f "$SUBAGENT_FILE" && -n "$AGENT_ID" ]]; then
  # Remove the specific agent ID line
  grep -v "^${AGENT_ID}$" "$SUBAGENT_FILE" > "${SUBAGENT_FILE}.tmp" 2>/dev/null
  mv "${SUBAGENT_FILE}.tmp" "$SUBAGENT_FILE" 2>/dev/null
  
  # If file is empty, remove it
  if [[ ! -s "$SUBAGENT_FILE" ]]; then
    rm -f "$SUBAGENT_FILE"
  fi
fi

exit 0
