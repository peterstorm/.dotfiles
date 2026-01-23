#!/bin/bash
# Complete wave gate after review passes
# Called by task-planner skill after confirming no critical findings
#
# Usage: bash ~/.claude/hooks/helpers/complete-wave-gate.sh [--wave N]
# If --wave not specified, uses current_wave from state

set -e

TASK_GRAPH=".claude/state/active_task_graph.json"
LOCK_FILE=".claude/state/.task_graph.lock"

if [[ ! -f "$TASK_GRAPH" ]]; then
  echo "ERROR: No active task graph at $TASK_GRAPH"
  exit 1
fi

# Parse args
WAVE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --wave) WAVE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Acquire cross-platform lock
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

# Default to current wave
if [[ -z "$WAVE" ]]; then
  WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
fi

echo "Completing wave $WAVE gate..."

# Check tests passed
TESTS_PASSED=$(jq -r ".wave_gates[\"$WAVE\"].tests_passed // false" "$TASK_GRAPH")
if [[ "$TESTS_PASSED" != "true" ]]; then
  echo "ERROR: Tests not passed for wave $WAVE"
  exit 1
fi

# Check no critical findings in wave tasks
CRITICAL_COUNT=$(jq -r "[.tasks[] | select(.wave == $WAVE) | .critical_findings // [] | length] | add // 0" "$TASK_GRAPH")
if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
  echo "ERROR: Wave $WAVE has $CRITICAL_COUNT critical findings. Fix before completing."
  exit 1
fi

# Get task IDs in this wave
TASK_IDS=$(jq -r ".tasks[] | select(.wave == $WAVE) | .id" "$TASK_GRAPH")

# Mark all wave tasks as "completed" and review_status = "passed"
jq "
  .tasks |= map(
    if .wave == $WAVE then
      .status = \"completed\" | .review_status = \"passed\"
    else . end
  ) |
  .wave_gates[\"$WAVE\"].reviews_complete = true |
  .wave_gates[\"$WAVE\"].blocked = false
" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Marked wave $WAVE tasks completed."

# Update GitHub Issue checkboxes
ISSUE=$(jq -r '.issue // empty' "$TASK_GRAPH")
if [[ -n "$ISSUE" && "$ISSUE" != "null" ]]; then
  BODY=$(gh issue view "$ISSUE" --json body -q '.body' 2>/dev/null)
  if [[ -n "$BODY" ]]; then
    UPDATED="$BODY"
    for TASK_ID in $TASK_IDS; do
      UPDATED=$(echo "$UPDATED" | sed "s/- \[ \] $TASK_ID:/- [x] $TASK_ID:/")
    done
    gh issue edit "$ISSUE" --body "$UPDATED" 2>/dev/null && \
      echo "Updated checkboxes in issue #$ISSUE"
  fi
fi

# Advance to next wave if there is one
MAX_WAVE=$(jq -r '[.tasks[].wave] | max' "$TASK_GRAPH")
NEXT_WAVE=$((WAVE + 1))

if [[ "$NEXT_WAVE" -le "$MAX_WAVE" ]]; then
  # Initialize next wave gate
  jq "
    .current_wave = $NEXT_WAVE |
    .wave_gates[\"$NEXT_WAVE\"] = {
      \"impl_complete\": false,
      \"tests_passed\": null,
      \"reviews_complete\": false,
      \"blocked\": false
    }
  " "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

  echo "Advanced to wave $NEXT_WAVE."
  echo ""
  echo "Ready to execute wave $NEXT_WAVE tasks."
else
  echo ""
  echo "=== All waves complete! ==="
  echo "Run /task-planner --complete to finalize."
fi

exit 0
