#!/bin/bash
# Complete wave gate after review passes
# Verifies per-task test evidence, review completion, AND no critical findings
# Called by wave-gate skill after confirming no critical findings
#
# Enforcement chain:
#   tests_passed      → set by SubagentStop hook (update-task-status.sh)
#   new_tests_written → set by SubagentStop hook (verify-new-tests.sh)
#   review_status     → set by SubagentStop hook (store-reviewer-findings.sh)
#   All unfakeable    → guard-state-file.sh blocks direct state writes
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
echo ""

# --- 1. Verify per-task test evidence (set by SubagentStop hook) ---
WAVE_TASKS=$(jq -r "[.tasks[] | select(.wave == $WAVE)] | length" "$TASK_GRAPH")
TASKS_WITH_TESTS=$(jq -r "[.tasks[] | select(.wave == $WAVE and .tests_passed == true)] | length" "$TASK_GRAPH")

if [[ "$TASKS_WITH_TESTS" -ne "$WAVE_TASKS" ]]; then
  MISSING=$(jq -r "[.tasks[] | select(.wave == $WAVE and (.tests_passed == false or .tests_passed == null))] | .[].id" "$TASK_GRAPH")
  echo "FAILED: Not all wave $WAVE tasks have test evidence."
  echo "  Tasks with tests: $TASKS_WITH_TESTS/$WAVE_TASKS"
  echo "  Missing evidence: $MISSING"
  echo ""
  echo "Test evidence is set by SubagentStop hook from agent transcripts."
  echo "Re-spawn agents that failed to run tests."
  exit 1
fi

echo "1. Test evidence verified ($TASKS_WITH_TESTS/$WAVE_TASKS tasks):"
jq -r ".tasks[] | select(.wave == $WAVE) | \"     \\(.id): \\(.test_evidence // \"evidence present\")\"" "$TASK_GRAPH"

# --- 1b. Verify NEW tests were written OR not required (set by SubagentStop verify-new-tests.sh) ---
# Logic: task passes if new_tests_required == false OR new_tests_written == true
TASKS_NEW_TEST_OK=$(jq -r "[.tasks[] | select(.wave == $WAVE and ((.new_tests_required == false) or (.new_tests_written == true)))] | length" "$TASK_GRAPH")

if [[ "$TASKS_NEW_TEST_OK" -ne "$WAVE_TASKS" ]]; then
  MISSING_NEW=$(jq -r "[.tasks[] | select(.wave == $WAVE and .new_tests_required != false and (.new_tests_written == false or .new_tests_written == null))] | .[].id" "$TASK_GRAPH")
  echo ""
  echo "FAILED: Not all wave $WAVE tasks satisfied new-test requirement."
  echo "  Tasks satisfied: $TASKS_NEW_TEST_OK/$WAVE_TASKS"
  echo "  Missing new-test evidence: $MISSING_NEW"
  echo ""
  echo "Tasks must write NEW tests unless new_tests_required=false."
  echo "Re-spawn agents that failed to write tests."
  exit 1
fi

echo "   New tests verified ($TASKS_NEW_TEST_OK/$WAVE_TASKS tasks):"
jq -r ".tasks[] | select(.wave == $WAVE) | \"     \\(.id): \\(.new_test_evidence // (if .new_tests_required == false then \"not required\" else \"new tests present\" end))\"" "$TASK_GRAPH"

# Mark wave tests_passed (derived from per-task evidence)
jq ".wave_gates[\"$WAVE\"].tests_passed = true" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

# --- 2. Verify reviews were conducted (set by SubagentStop hook) ---
TASKS_REVIEWED=$(jq -r "[.tasks[] | select(.wave == $WAVE and (.review_status == \"passed\" or .review_status == \"blocked\"))] | length" "$TASK_GRAPH")

if [[ "$TASKS_REVIEWED" -ne "$WAVE_TASKS" ]]; then
  UNREVIEWED=$(jq -r "[.tasks[] | select(.wave == $WAVE and .review_status == \"pending\")] | .[].id" "$TASK_GRAPH")
  echo ""
  echo "FAILED: Not all wave $WAVE tasks have been reviewed."
  echo "  Tasks reviewed: $TASKS_REVIEWED/$WAVE_TASKS"
  echo "  Unreviewed: $UNREVIEWED"
  echo ""
  echo "Review status is set by SubagentStop hook when review agents complete."
  echo "Spawn review-invoker agents for unreviewed tasks."
  exit 1
fi

echo "2. Reviews verified ($TASKS_REVIEWED/$WAVE_TASKS tasks):"
jq -r ".tasks[] | select(.wave == $WAVE) | \"     \\(.id): \\(.review_status)\"" "$TASK_GRAPH"

# --- 3. Check no critical findings in wave tasks ---
CRITICAL_COUNT=$(jq -r "[.tasks[] | select(.wave == $WAVE) | .critical_findings // [] | length] | add // 0" "$TASK_GRAPH")
if [[ "$CRITICAL_COUNT" -gt 0 ]]; then
  echo ""
  echo "FAILED: Wave $WAVE has $CRITICAL_COUNT critical findings. Fix before completing."
  jq -r ".tasks[] | select(.wave == $WAVE) | select((.critical_findings // []) | length > 0) | \"  \\(.id): \\(.critical_findings | join(\", \"))\"" "$TASK_GRAPH"
  exit 1
fi

echo "3. No critical findings."

# --- All checks passed — advance wave ---
echo ""
echo "All checks passed. Advancing..."

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
ISSUE=$(jq -r '.github_issue // .issue // empty' "$TASK_GRAPH")
REPO=$(jq -r '.github_repo // empty' "$TASK_GRAPH")
if [[ -n "$ISSUE" && "$ISSUE" != "null" ]]; then
  REPO_FLAG=""
  [[ -n "$REPO" && "$REPO" != "null" ]] && REPO_FLAG="--repo $REPO"
  BODY=$(gh issue view "$ISSUE" $REPO_FLAG --json body -q '.body' 2>/dev/null)
  if [[ -n "$BODY" ]]; then
    UPDATED="$BODY"
    for TASK_ID in $TASK_IDS; do
      UPDATED=$(echo "$UPDATED" | sed "s/- \[ \] $TASK_ID:/- [x] $TASK_ID:/")
    done
    gh issue edit "$ISSUE" $REPO_FLAG --body "$UPDATED" 2>/dev/null && \
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
