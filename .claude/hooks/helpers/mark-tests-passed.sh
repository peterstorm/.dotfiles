#!/bin/bash
# Read-only verifier for per-task test evidence
# Does NOT modify state — only reports status
# Test evidence is set by SubagentStop hook (update-task-status.sh)
# Wave advancement is done by complete-wave-gate.sh (which also verifies)
#
# Usage: bash ~/.claude/hooks/helpers/mark-tests-passed.sh [--wave N]
# Exit 0 = all tasks have evidence, Exit 1 = missing evidence

TASK_GRAPH=".claude/state/active_task_graph.json"

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
TASKS_WITH_NEW_TESTS=$(jq -r "[.tasks[] | select(.wave == $WAVE and .new_tests_written == true)] | length" "$TASK_GRAPH")

echo "Wave $WAVE test evidence: $TASKS_WITH_TESTS/$WAVE_TASKS tasks passed, $TASKS_WITH_NEW_TESTS/$WAVE_TASKS wrote new tests"
jq -r ".tasks[] | select(.wave == $WAVE) | \"  \\(.id): tests=\\(if .tests_passed then \"PASS\" else \"MISSING\" end) new=\\(if .new_tests_written then \"YES (\\(.new_test_evidence))\" else \"MISSING\" end)\"" "$TASK_GRAPH"

ALL_PASS=true

if [[ "$TASKS_WITH_TESTS" -ne "$WAVE_TASKS" ]]; then
  MISSING=$(jq -r "[.tasks[] | select(.wave == $WAVE and (.tests_passed == false or .tests_passed == null))] | .[].id" "$TASK_GRAPH")
  echo ""
  echo "Missing test pass evidence: $MISSING"
  ALL_PASS=false
fi

if [[ "$TASKS_WITH_NEW_TESTS" -ne "$WAVE_TASKS" ]]; then
  MISSING_NEW=$(jq -r "[.tasks[] | select(.wave == $WAVE and (.new_tests_written == false or .new_tests_written == null))] | .[].id" "$TASK_GRAPH")
  echo ""
  echo "Missing new-test evidence: $MISSING_NEW"
  echo "Agents must write NEW tests, not just rerun existing ones."
  ALL_PASS=false
fi

if [[ "$ALL_PASS" == "true" ]]; then
  echo ""
  echo "All tasks have test evidence and wrote new tests."
  exit 0
else
  echo ""
  echo "Evidence is set by SubagentStop hooks from agent transcripts and git diffs."
  exit 1
fi
