#!/usr/bin/env bash
# Force Explore agent to use haiku model

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

if [[ "$TOOL_NAME" == "Task" ]] && [[ "$SUBAGENT_TYPE" == "Explore" ]]; then
  echo "$INPUT" | jq '.tool_input.model = "haiku"'
else
  echo "$INPUT"
fi
