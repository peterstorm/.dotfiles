#!/bin/bash
# Block next wave tasks if current wave review not passed
# Only active when task graph exists

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Only check Task tool calls
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Task" ]] && exit 0

# Extract task ID from prompt (handles "Task ID: T1" or "**Task ID:** T1")
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.prompt // empty')
TASK_ID=$(echo "$PROMPT" | grep -oE '(\*\*)?Task ID:(\*\*)? ?(T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')
[[ -z "$TASK_ID" ]] && exit 0  # Not a planned task

# Get task's wave
TASK_WAVE=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .wave" "$TASK_GRAPH")
[[ -z "$TASK_WAVE" ]] && exit 0

CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")

# If trying to execute task in current wave, check if previous wave gate passed
if [[ "$TASK_WAVE" -eq "$CURRENT_WAVE" && "$CURRENT_WAVE" -gt 1 ]]; then
  PREV_WAVE=$((CURRENT_WAVE - 1))
  PREV_REVIEWS_COMPLETE=$(jq -r ".wave_gates[\"$PREV_WAVE\"].reviews_complete // false" "$TASK_GRAPH")
  PREV_BLOCKED=$(jq -r ".wave_gates[\"$PREV_WAVE\"].blocked // false" "$TASK_GRAPH")

  if [[ "$PREV_REVIEWS_COMPLETE" != "true" ]]; then
    echo "BLOCKED: Wave $PREV_WAVE review gate not passed."
    echo ""
    if [[ "$PREV_BLOCKED" == "true" ]]; then
      echo "Wave $PREV_WAVE is BLOCKED due to:"
      # Show what's blocking
      TESTS_PASSED=$(jq -r ".wave_gates[\"$PREV_WAVE\"].tests_passed // null" "$TASK_GRAPH")
      if [[ "$TESTS_PASSED" == "false" ]]; then
        echo "  - Integration tests failed"
      fi
      # Check for critical findings
      CRITICAL=$(jq -r "[.tasks[] | select(.wave == $PREV_WAVE) | .critical_findings[]] | length" "$TASK_GRAPH")
      if [[ "$CRITICAL" -gt 0 ]]; then
        echo "  - $CRITICAL critical review findings"
      fi
    else
      echo "Wave $PREV_WAVE gates not yet run. Complete the gate sequence first."
    fi
    echo ""
    echo "Run wave gate sequence before advancing to wave $CURRENT_WAVE."
    exit 2
  fi
fi

exit 0
