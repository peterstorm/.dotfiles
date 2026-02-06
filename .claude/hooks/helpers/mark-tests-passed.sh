#!/bin/bash
# Read-only verifier for per-task test evidence
# Does NOT modify state — only reports status
# Test evidence is set by SubagentStop hook (update-task-status.sh)
# Wave advancement is done by complete-wave-gate.sh (which also verifies)
#
# Usage: bash ~/.claude/hooks/helpers/mark-tests-passed.sh [--wave N]
# Exit 0 = all tasks have evidence, Exit 1 = missing evidence

TASK_GRAPH="${TASK_GRAPH:-.claude/state/active_task_graph.json}"

[[ ! -f "$TASK_GRAPH" ]] && { echo "ERROR: No active task graph"; exit 1; }

WAVE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --wave) WAVE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$WAVE" ]] && WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")

# Check per-task test evidence
WAVE_TASKS=$(jq -r "[.tasks[] | select(.wave == $WAVE)] | length" "$TASK_GRAPH")
TASKS_WITH_TESTS=$(jq -r "[.tasks[] | select(.wave == $WAVE and .tests_passed == true)] | length" "$TASK_GRAPH")
# Logic: task passes if new_tests_required == false OR new_tests_written == true
TASKS_NEW_TEST_OK=$(jq -r "[.tasks[] | select(.wave == $WAVE and ((.new_tests_required == false) or (.new_tests_written == true)))] | length" "$TASK_GRAPH")

echo "Wave $WAVE test evidence: $TASKS_WITH_TESTS/$WAVE_TASKS tasks passed, $TASKS_NEW_TEST_OK/$WAVE_TASKS satisfied new-test requirement"
jq -r ".tasks[] | select(.wave == $WAVE) | \"  \\(.id): tests=\\(if .tests_passed then \"PASS\" else \"MISSING\" end) new=\\(if .new_tests_required == false then \"N/A (not required)\" elif .new_tests_written then \"YES (\\(.new_test_evidence))\" else \"MISSING\" end)\"" "$TASK_GRAPH"

ALL_PASS=true

if [[ "$TASKS_WITH_TESTS" -ne "$WAVE_TASKS" ]]; then
  MISSING=$(jq -r "[.tasks[] | select(.wave == $WAVE and (.tests_passed == false or .tests_passed == null))] | .[].id" "$TASK_GRAPH")
  echo ""
  echo "Missing test pass evidence: $MISSING"
  ALL_PASS=false
fi

if [[ "$TASKS_NEW_TEST_OK" -ne "$WAVE_TASKS" ]]; then
  MISSING_NEW=$(jq -r "[.tasks[] | select(.wave == $WAVE and .new_tests_required != false and (.new_tests_written == false or .new_tests_written == null))] | .[].id" "$TASK_GRAPH")
  echo ""
  echo "Missing new-test evidence: $MISSING_NEW"
  echo "Tasks must write NEW tests unless new_tests_required=false."
  ALL_PASS=false
fi

if [[ "$ALL_PASS" == "true" ]]; then
  echo ""
  echo "All tasks have test evidence and satisfy new-test requirement."
  exit 0
else
  echo ""
  echo "Evidence is set by SubagentStop hooks from agent transcripts and git diffs."
  exit 1
fi
