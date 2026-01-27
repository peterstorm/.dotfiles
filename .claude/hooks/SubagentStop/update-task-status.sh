#!/bin/bash
# Update task status when impl agent completes
# Marks task "implemented" (not "completed" - that happens after review gate)
# Extracts test evidence from agent transcript for per-task test verification
# Only active when task graph exists

TASK_GRAPH=".claude/state/active_task_graph.json"
LOCK_FILE=".claude/state/.task_graph.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Read hook input from stdin and extract transcript text
INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

source ~/.claude/hooks/helpers/parse-transcript.sh
PROMPT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  PROMPT=$(parse_transcript "$TRANSCRIPT_PATH")
fi

# Match "Task ID: T1" or "**Task ID:** T1" (markdown bold)
TASK_ID=$(echo "$PROMPT" | grep -oE '(\*\*)?Task ID:(\*\*)? ?(T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')

[[ -z "$TASK_ID" ]] && exit 0  # Not a tracked task, ignore

# Skip review agents — they don't implement tasks
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=""
if [[ -n "$AGENT_ID" && -f "/tmp/claude-subagents/${AGENT_ID}.type" ]]; then
  AGENT_TYPE=$(cat "/tmp/claude-subagents/${AGENT_ID}.type")
fi
case "$AGENT_TYPE" in
  *review*|*reviewer*) exit 0 ;;
esac

# Use cross-platform file locking
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

# Verify task exists and isn't already completed
TASK_STATUS=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .status" "$TASK_GRAPH")
[[ -z "$TASK_STATUS" || "$TASK_STATUS" == "completed" ]] && exit 0
# Allow re-extraction if implemented but missing test evidence
if [[ "$TASK_STATUS" == "implemented" ]]; then
  HAS_EVIDENCE=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .tests_passed // \"null\"" "$TASK_GRAPH")
  [[ "$HAS_EVIDENCE" != "null" ]] && exit 0
fi

# --- Extract test evidence from agent transcript ---
TESTS_PASSED=false
TEST_EVIDENCE=""

# Java/Maven: "BUILD SUCCESS" + "Tests run: X, Failures: 0, Errors: 0"
if echo "$PROMPT" | grep -q "BUILD SUCCESS"; then
  MAVEN_RESULTS=$(echo "$PROMPT" | grep -oE 'Tests run: [0-9]+, Failures: 0, Errors: 0' | tail -1)
  if [[ -n "$MAVEN_RESULTS" ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="maven: $MAVEN_RESULTS"
  fi
fi

# Node/Mocha/Vitest: "N passing" without "N failing"
if [[ "$TESTS_PASSED" == "false" ]] && echo "$PROMPT" | grep -qE '[0-9]+ passing'; then
  PASSING=$(echo "$PROMPT" | grep -oE '[0-9]+ passing' | tail -1)
  FAILING=$(echo "$PROMPT" | grep -oE '[0-9]+ failing' | tail -1)
  if [[ -z "$FAILING" ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="node: $PASSING"
  fi
fi

# Vitest alternative: "Tests  X passed" or "Test Files  X passed"
if [[ "$TESTS_PASSED" == "false" ]] && echo "$PROMPT" | grep -qE 'Tests?\s+[0-9]+ passed'; then
  VITEST_RESULTS=$(echo "$PROMPT" | grep -oE 'Tests?\s+[0-9]+ passed' | tail -1)
  VITEST_FAILED=$(echo "$PROMPT" | grep -oE 'Tests?\s+[0-9]+ failed' | tail -1)
  if [[ -z "$VITEST_FAILED" ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="vitest: $VITEST_RESULTS"
  fi
fi

# pytest: "X passed" without "X failed"
if [[ "$TESTS_PASSED" == "false" ]] && echo "$PROMPT" | grep -qE '[0-9]+ passed'; then
  PYTEST_PASSED=$(echo "$PROMPT" | grep -oE '[0-9]+ passed' | tail -1)
  PYTEST_FAILED=$(echo "$PROMPT" | grep -oE '[0-9]+ failed' | tail -1)
  if [[ -z "$PYTEST_FAILED" ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="pytest: $PYTEST_PASSED"
  fi
fi

# --- Mark task as "implemented" with test status ---
jq "
  .tasks |= map(if .id == \"$TASK_ID\" then
    .status = \"implemented\" |
    .tests_passed = $TESTS_PASSED |
    .test_evidence = \"$TEST_EVIDENCE\"
  else . end) |
  .executing_tasks |= (. // [] | map(select(. != \"$TASK_ID\")))
" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Task $TASK_ID implemented."
if [[ "$TESTS_PASSED" == "true" ]]; then
  echo "  Tests passed: $TEST_EVIDENCE"
else
  echo "  WARNING: No test pass evidence found in agent output"
fi

# Check if all wave tasks are now "implemented" or "completed"
CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
NOT_IMPL=$(jq -r "[.tasks[] | select(.wave == $CURRENT_WAVE and .status != \"implemented\" and .status != \"completed\")] | length" "$TASK_GRAPH")

if [[ "$NOT_IMPL" -eq 0 ]]; then
  # Mark wave impl_complete
  jq ".wave_gates[\"$CURRENT_WAVE\"].impl_complete = true" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

  echo ""
  echo "========================================="
  echo "  Wave $CURRENT_WAVE implementation complete"
  echo "========================================="
  echo ""
  echo "Run: /wave-gate"
  echo ""
  echo "(Tests + parallel code review + advance)"
fi

# Lock released automatically when script exits
exit 0
