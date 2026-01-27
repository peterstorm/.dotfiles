#!/bin/bash
# Clean up subagent flag file and type file when subagent completes
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')

[[ -z "$AGENT_ID" ]] && exit 0

# Remove this agent from active list (locked to prevent race with parallel completions)
SUBAGENT_FILE="/tmp/claude-subagents/${SESSION_ID}.active"
LOCK_FILE="/tmp/claude-subagents/${SESSION_ID}.cleanup.lock"

if [[ -f "$SUBAGENT_FILE" ]]; then
  source ~/.claude/hooks/helpers/lock.sh
  acquire_lock "$LOCK_FILE" auto

  grep -v "^${AGENT_ID}$" "$SUBAGENT_FILE" > "${SUBAGENT_FILE}.tmp" 2>/dev/null
  mv "${SUBAGENT_FILE}.tmp" "$SUBAGENT_FILE" 2>/dev/null

  # If file is empty, remove it
  if [[ ! -s "$SUBAGENT_FILE" ]]; then
    rm -f "$SUBAGENT_FILE"
  fi
fi

# Clean up agent type file
rm -f "/tmp/claude-subagents/${AGENT_ID}.type"

exit 0
