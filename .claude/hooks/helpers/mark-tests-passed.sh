#!/bin/bash
# Mark wave tests as passed/failed
# Usage: bash ~/.claude/hooks/helpers/mark-tests-passed.sh [--wave N] [--failed]

set -e

TASK_GRAPH=".claude/state/active_task_graph.json"
LOCK_FILE=".claude/state/.task_graph.lock"

[[ ! -f "$TASK_GRAPH" ]] && { echo "ERROR: No active task graph"; exit 1; }

WAVE=""
PASSED="true"

while [[ $# -gt 0 ]]; do
  case $1 in
    --wave) WAVE="$2"; shift 2 ;;
    --failed) PASSED="false"; shift ;;
    *) shift ;;
  esac
done

# Acquire cross-platform lock
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

[[ -z "$WAVE" ]] && WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")

jq "
  .wave_gates[\"$WAVE\"].tests_passed = $PASSED |
  .wave_gates[\"$WAVE\"].blocked = (if $PASSED then false else true end)
" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

if [[ "$PASSED" == "true" ]]; then
  echo "Wave $WAVE tests passed. Ready for code review."
else
  echo "Wave $WAVE tests FAILED. Fix before proceeding."
fi
