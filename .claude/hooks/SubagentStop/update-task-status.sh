#!/bin/bash
# Update task status when impl agent completes
# Merged: update-task-status + verify-new-tests (single lock, single transcript parse)
#
# Responsibilities:
# 1. Mark task "implemented" (not "completed" — that happens after review gate)
# 2. Extract test evidence from ACTUAL Bash tool output (anti-spoofing)
# 3. Verify new tests written + assertion density check
# 4. Write all fields atomically via state-file-write.sh
#
# Supports cross-repo: finds task graph via session-scoped path if not in cwd

# Read hook input from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

# Resolve task graph path (supports cross-repo via session-scoped path)
source ~/.claude/hooks/helpers/resolve-task-graph.sh
TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
export TASK_GRAPH  # For state-file-write.sh
export SESSION_ID

source ~/.claude/hooks/helpers/parse-transcript.sh
source ~/.claude/hooks/helpers/parse-files-modified.sh
source ~/.claude/hooks/helpers/parse-bash-test-output.sh
PROMPT=""
FILES_MODIFIED=""
BASH_TEST_OUTPUT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  PROMPT=$(parse_transcript "$TRANSCRIPT_PATH")
  FILES_MODIFIED=$(parse_files_modified "$TRANSCRIPT_PATH")
  BASH_TEST_OUTPUT=$(parse_bash_test_output "$TRANSCRIPT_PATH")
fi

# Get agent type early — needed for crash detection and review filtering
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# Skip review agents — they don't implement tasks
case "$AGENT_TYPE" in
  *review*|*reviewer*|spec-check-invoker) exit 0 ;;
esac

# Extract task ID using flexible helper (handles multiple formats)
source ~/.claude/hooks/helpers/extract-task-id.sh
TASK_ID=$(extract_task_id "$PROMPT")

# Crash detection: impl agent completed but no parseable task ID
if [[ -z "$TASK_ID" ]]; then
  case "$AGENT_TYPE" in
    code-implementer-agent|java-test-agent|ts-test-agent|frontend-agent|security-agent|k8s-agent|keycloak-agent|dotfiles-agent)
      EXECUTING=$(jq -r '.executing_tasks // [] | .[]' "$TASK_GRAPH" 2>/dev/null)
      if [[ -n "$EXECUTING" ]]; then
        echo "CRASH DETECTED: impl agent ($AGENT_TYPE) completed without task ID"
        echo "Marking executing tasks as failed: $EXECUTING"

        bash ~/.claude/hooks/helpers/state-file-write.sh '
          (.executing_tasks // []) as $exec |
          .tasks |= map(
            if .id as $id | $exec | index($id) then
              .status = "failed" |
              .failure_reason = "agent_crash: no task ID in output" |
              .retry_count = ((.retry_count // 0) + 1)
            else . end
          ) |
          .executing_tasks = []
        '
      fi
      ;;
  esac
  exit 0
fi

# Verify task exists and isn't already completed
TASK_STATUS=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .status" "$TASK_GRAPH")
[[ -z "$TASK_STATUS" || "$TASK_STATUS" == "completed" ]] && exit 0
# Allow re-extraction if implemented but missing test evidence
if [[ "$TASK_STATUS" == "implemented" ]]; then
  HAS_EVIDENCE=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .tests_passed // \"null\"" "$TASK_GRAPH")
  [[ "$HAS_EVIDENCE" != "null" ]] && exit 0
fi

# ===== SECTION 1: Extract test evidence from Bash tool output (anti-spoofing) =====
TESTS_PASSED=false
TEST_EVIDENCE=""

# Use BASH_TEST_OUTPUT (from actual Bash tool_use blocks) not raw PROMPT
TEST_SOURCE="$BASH_TEST_OUTPUT"

# Java/Maven: "BUILD SUCCESS" + "Tests run: X, Failures: 0, Errors: 0"
if echo "$TEST_SOURCE" | grep -q "BUILD SUCCESS"; then
  CLEAN_SOURCE=$(echo "$TEST_SOURCE" | sed 's/\*\*//g')
  MAVEN_RESULTS=$(echo "$CLEAN_SOURCE" | grep -oE 'Tests run: [0-9]+, Failures: 0, Errors: 0' | tail -1)
  if [[ -n "$MAVEN_RESULTS" ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="maven: $MAVEN_RESULTS"
  fi
fi

# Node/Mocha/Vitest: "N passing" without "N failing"
if [[ "$TESTS_PASSED" == "false" ]] && echo "$TEST_SOURCE" | grep -qE '[0-9]+ passing'; then
  PASSING=$(echo "$TEST_SOURCE" | grep -oE '[0-9]+ passing' | tail -1)
  FAIL_COUNT=$(echo "$TEST_SOURCE" | grep -oE '([0-9]+) failing' | grep -oE '[0-9]+' | tail -1)
  if [[ -z "$FAIL_COUNT" || "$FAIL_COUNT" -eq 0 ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="node: $PASSING"
  fi
fi

# Vitest alternative: "Tests  X passed" or "Test Files  X passed"
if [[ "$TESTS_PASSED" == "false" ]] && echo "$TEST_SOURCE" | grep -qE 'Tests?\s+[0-9]+ passed'; then
  VITEST_RESULTS=$(echo "$TEST_SOURCE" | grep -oE 'Tests?\s+[0-9]+ passed' | tail -1)
  VITEST_FAILED=$(echo "$TEST_SOURCE" | grep -oE 'Tests?\s+[0-9]+ failed' | tail -1)
  if [[ -z "$VITEST_FAILED" ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="vitest: $VITEST_RESULTS"
  fi
fi

# pytest: "X passed" without "X failed"
if [[ "$TESTS_PASSED" == "false" ]] && echo "$TEST_SOURCE" | grep -qE '[0-9]+ passed'; then
  PYTEST_PASSED=$(echo "$TEST_SOURCE" | grep -oE '[0-9]+ passed' | tail -1)
  PYTEST_FAIL_COUNT=$(echo "$TEST_SOURCE" | grep -oE '([0-9]+) failed' | grep -oE '[0-9]+' | tail -1)
  if [[ -z "$PYTEST_FAIL_COUNT" || "$PYTEST_FAIL_COUNT" -eq 0 ]]; then
    TESTS_PASSED=true
    TEST_EVIDENCE="pytest: $PYTEST_PASSED"
  fi
fi

# ===== SECTION 2: Verify new tests written + assertion density =====
NEW_TESTS_WRITTEN=false
NEW_TEST_EVIDENCE=""

# Check if new tests are required for this task
NEW_TESTS_REQUIRED=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .new_tests_required" "$TASK_GRAPH")
if [[ "$NEW_TESTS_REQUIRED" == "false" ]]; then
  NEW_TESTS_WRITTEN=false
  NEW_TEST_EVIDENCE="new_tests_required=false (skipped)"
elif git rev-parse --git-dir &>/dev/null; then
  # --- Detect new test methods via git diff ---
  FULL_DIFF=""
  USE_SHA_FALLBACK=false

  if [[ -n "$FILES_MODIFIED" ]]; then
    DIFF_UNSTAGED=$(echo "$FILES_MODIFIED" | xargs git diff -- 2>/dev/null)
    DIFF_STAGED=$(echo "$FILES_MODIFIED" | xargs git diff --cached -- 2>/dev/null)
    DIFF_UNTRACKED=""
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      if [[ -f "$file" ]] && ! git ls-files --error-unmatch "$file" &>/dev/null; then
        DIFF_UNTRACKED+=$(git diff --no-index /dev/null "$file" 2>/dev/null)
        DIFF_UNTRACKED+=$'\n'
      fi
    done <<< "$FILES_MODIFIED"
    FULL_DIFF="${DIFF_UNSTAGED}
${DIFF_STAGED}
${DIFF_UNTRACKED}"
    if [[ -z "$(echo "$FULL_DIFF" | tr -d '[:space:]')" ]]; then
      USE_SHA_FALLBACK=true
    fi
  fi

  if [[ -z "$FILES_MODIFIED" ]] || [[ "$USE_SHA_FALLBACK" == "true" ]]; then
    START_SHA=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .start_sha // empty" "$TASK_GRAPH")
    DIFF=""
    if [[ -n "$START_SHA" ]]; then
      DIFF=$(git diff "$START_SHA" HEAD 2>/dev/null)
    else
      DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
      [[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"
      MERGE_BASE=$(git merge-base HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null)
      if [[ -n "$MERGE_BASE" ]]; then
        DIFF=$(git diff "$MERGE_BASE" HEAD 2>/dev/null)
      else
        DIFF=$(git diff HEAD~1 HEAD 2>/dev/null)
      fi
    fi
    DIFF_UNSTAGED=$(git diff 2>/dev/null)
    DIFF_STAGED=$(git diff --cached 2>/dev/null)
    FULL_DIFF="${DIFF}
${DIFF_UNSTAGED}
${DIFF_STAGED}"
  fi

  # Count new test methods
  NEW_TESTS_FOUND=0
  NEW_TEST_DETAILS=""

  count_matches() {
    local count
    count=$(echo "$1" | grep -cE "$2" 2>/dev/null || echo 0)
    count=${count//[^0-9]/}
    echo "${count:-0}"
  }

  # Java: @Test, @Property, @ParameterizedTest
  JAVA_TESTS=$(count_matches "$FULL_DIFF" '^\+.*@(Test|Property|ParameterizedTest)\b')
  if [[ "$JAVA_TESTS" -gt 0 ]]; then
    NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + JAVA_TESTS))
    NEW_TEST_DETAILS="${NEW_TEST_DETAILS}java: ${JAVA_TESTS} new @Test/@Property methods; "
  fi

  # TypeScript/JavaScript: it(, test(, describe(
  TS_TESTS=$(count_matches "$FULL_DIFF" '^\+.*[[:space:]](it|test|describe)\(')
  if [[ "$TS_TESTS" -gt 0 ]]; then
    NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + TS_TESTS))
    NEW_TEST_DETAILS="${NEW_TEST_DETAILS}ts/js: ${TS_TESTS} new it/test/describe blocks; "
  fi

  # Python: def test_, class Test
  PY_TESTS=$(count_matches "$FULL_DIFF" '^\+.*(def test_|class Test)')
  if [[ "$PY_TESTS" -gt 0 ]]; then
    NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + PY_TESTS))
    NEW_TEST_DETAILS="${NEW_TEST_DETAILS}python: ${PY_TESTS} new test functions/classes; "
  fi

  NEW_TEST_DETAILS=$(echo "$NEW_TEST_DETAILS" | sed 's/; $//')

  # --- Assertion density check ---
  ASSERTION_COUNT=0
  if [[ "$NEW_TESTS_FOUND" -gt 0 ]]; then
    JAVA_ASSERTS=$(count_matches "$FULL_DIFF" '^\+.*(assertThat|assertEquals|assertTrue|assertFalse|assertNotNull|assertThrows|verify\()')
    ASSERTION_COUNT=$((ASSERTION_COUNT + JAVA_ASSERTS))

    TS_ASSERTS=$(count_matches "$FULL_DIFF" '^\+.*(expect\(|assert\.|toEqual|toBe|toHaveBeenCalled|toThrow|\.should\.)')
    ASSERTION_COUNT=$((ASSERTION_COUNT + TS_ASSERTS))

    PY_ASSERTS=$(count_matches "$FULL_DIFF" '^\+.*(assert [^=]|assertEqual|assertRaises|assertTrue|assertFalse|assertIn)')
    ASSERTION_COUNT=$((ASSERTION_COUNT + PY_ASSERTS))
  fi

  # Determine new-test result
  if [[ "$NEW_TESTS_FOUND" -gt 0 && "$ASSERTION_COUNT" -gt 0 ]]; then
    NEW_TESTS_WRITTEN=true
    NEW_TEST_EVIDENCE="$NEW_TESTS_FOUND new test methods, $ASSERTION_COUNT assertions ($NEW_TEST_DETAILS)"
  elif [[ "$NEW_TESTS_FOUND" -gt 0 && "$ASSERTION_COUNT" -eq 0 ]]; then
    NEW_TESTS_WRITTEN=false
    NEW_TEST_EVIDENCE="$NEW_TESTS_FOUND test methods but 0 assertions found (empty stubs?)"
  fi
fi

# ===== SECTION 3: Atomic state write =====
# Convert files_modified to JSON array
if [[ -n "$FILES_MODIFIED" ]]; then
  FILES_JSON=$(echo "$FILES_MODIFIED" | jq -R -s 'split("\n") | map(select(length > 0))')
else
  FILES_JSON="[]"
fi

# Single atomic write for all fields
bash ~/.claude/hooks/helpers/state-file-write.sh \
  --argjson files "$FILES_JSON" \
  --argjson tests_passed "$TESTS_PASSED" \
  --argjson new_tests "$NEW_TESTS_WRITTEN" \
  --arg test_evidence "$TEST_EVIDENCE" \
  --arg new_test_evidence "$NEW_TEST_EVIDENCE" \
  --arg task_id "$TASK_ID" \
  '
  .tasks |= map(if .id == $task_id then
    .status = "implemented" |
    .tests_passed = $tests_passed |
    .test_evidence = $test_evidence |
    .files_modified = $files |
    .new_tests_written = $new_tests |
    .new_test_evidence = $new_test_evidence
  else . end) |
  .executing_tasks |= (. // [] | map(select(. != $task_id)))
  '

echo "Task $TASK_ID implemented."
if [[ -n "$FILES_MODIFIED" ]]; then
  FILE_COUNT=$(echo "$FILES_MODIFIED" | wc -l | tr -d ' ')
  echo "  Files modified: $FILE_COUNT"
fi
if [[ "$TESTS_PASSED" == "true" ]]; then
  echo "  Tests passed: $TEST_EVIDENCE (from Bash tool output)"
else
  echo "  WARNING: No test pass evidence in Bash tool output"
fi
if [[ "$NEW_TESTS_WRITTEN" == "true" ]]; then
  echo "  New tests: $NEW_TEST_EVIDENCE"
elif [[ "$NEW_TESTS_REQUIRED" == "false" ]]; then
  echo "  New tests: not required"
elif [[ -n "$NEW_TEST_EVIDENCE" ]]; then
  echo "  WARNING: $NEW_TEST_EVIDENCE"
else
  echo "  WARNING: No new test methods detected in git diff"
fi

# Check if all wave tasks are now "implemented" or "completed"
CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
NOT_IMPL=$(jq -r "[.tasks[] | select(.wave == $CURRENT_WAVE and .status != \"implemented\" and .status != \"completed\")] | length" "$TASK_GRAPH")

if [[ "$NOT_IMPL" -gt 0 ]]; then
  REMAINING=$(jq -r "[.tasks[] | select(.wave == $CURRENT_WAVE and .status != \"implemented\" and .status != \"completed\")] | .[].id" "$TASK_GRAPH" | tr '\n' ', ' | sed 's/,$//')
  echo "Remaining in wave $CURRENT_WAVE: $REMAINING"
fi

if [[ "$NOT_IMPL" -eq 0 ]]; then
  bash ~/.claude/hooks/helpers/state-file-write.sh \
    --arg wave "$CURRENT_WAVE" \
    '.wave_gates[$wave].impl_complete = true'

  echo ""
  echo "========================================="
  echo "  Wave $CURRENT_WAVE implementation complete"
  echo "========================================="
  echo ""
  echo "Run: /wave-gate"
  echo ""
  echo "(Tests + parallel code review + advance)"
fi

exit 0
