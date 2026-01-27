#!/bin/bash
# Verify implementation agents wrote NEW tests (not just reran existing)
# Checks git diff for new test method patterns (@Test, it(, test(, describe()
# Only runs for implementation agents (skips reviewers)
# Sets new_tests_written + new_test_evidence in task state

TASK_GRAPH=".claude/state/active_task_graph.json"
LOCK_FILE=".claude/state/.task_graph.lock"

[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Read hook input and extract transcript
INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

source ~/.claude/hooks/helpers/parse-transcript.sh
PROMPT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  PROMPT=$(parse_transcript "$TRANSCRIPT_PATH")
fi

# Extract task ID
TASK_ID=$(echo "$PROMPT" | grep -oE '(\*\*)?Task ID:(\*\*)? ?(T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')
[[ -z "$TASK_ID" ]] && exit 0

# Skip review agents — gate on agent field, not status (avoids ordering issues)
TASK_AGENT=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .agent" "$TASK_GRAPH")
case "$TASK_AGENT" in
  *review*|*reviewer*) exit 0 ;;
esac

# Skip if already verified
HAS_NEW_TESTS=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .new_tests_written // \"null\"" "$TASK_GRAPH")
[[ "$HAS_NEW_TESTS" != "null" ]] && exit 0

# --- Detect new test methods via git diff ---
# Prefer per-task start_sha (set by validate-task-execution.sh PreToolUse hook)
# to scope detection to THIS task's changes, not the whole branch.
START_SHA=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .start_sha // empty" "$TASK_GRAPH")

DIFF=""
if [[ -n "$START_SHA" ]]; then
  # Per-task baseline: only changes made by this task's agent
  DIFF=$(git diff "$START_SHA" HEAD 2>/dev/null)
else
  # Fallback: branch merge-base (all new code on this branch)
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  [[ -z "$DEFAULT_BRANCH" ]] && DEFAULT_BRANCH="main"
  MERGE_BASE=$(git merge-base HEAD "origin/$DEFAULT_BRANCH" 2>/dev/null)
  if [[ -n "$MERGE_BASE" ]]; then
    DIFF=$(git diff "$MERGE_BASE" HEAD 2>/dev/null)
  else
    DIFF=$(git diff HEAD~1 HEAD 2>/dev/null)
  fi
fi

# Also include uncommitted changes (agent may not have committed yet)
DIFF_UNSTAGED=$(git diff 2>/dev/null)
DIFF_STAGED=$(git diff --cached 2>/dev/null)
FULL_DIFF="${DIFF}
${DIFF_UNSTAGED}
${DIFF_STAGED}"

NEW_TESTS_FOUND=0
NEW_TEST_DETAILS=""

# Java: @Test, @Property, @ParameterizedTest (new lines only)
JAVA_TESTS=$(echo "$FULL_DIFF" | grep -cE '^\+.*@(Test|Property|ParameterizedTest)\b' 2>/dev/null || echo 0)
if [[ "$JAVA_TESTS" -gt 0 ]]; then
  NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + JAVA_TESTS))
  NEW_TEST_DETAILS="${NEW_TEST_DETAILS}java: ${JAVA_TESTS} new @Test/@Property methods; "
fi

# TypeScript/JavaScript: it(, test(, describe( (new lines only)
TS_TESTS=$(echo "$FULL_DIFF" | grep -cE '^\+.*[[:space:]](it|test|describe)\(' 2>/dev/null || echo 0)
if [[ "$TS_TESTS" -gt 0 ]]; then
  NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + TS_TESTS))
  NEW_TEST_DETAILS="${NEW_TEST_DETAILS}ts/js: ${TS_TESTS} new it/test/describe blocks; "
fi

# Python: def test_, class Test (new lines only)
PY_TESTS=$(echo "$FULL_DIFF" | grep -cE '^\+.*(def test_|class Test)' 2>/dev/null || echo 0)
if [[ "$PY_TESTS" -gt 0 ]]; then
  NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + PY_TESTS))
  NEW_TEST_DETAILS="${NEW_TEST_DETAILS}python: ${PY_TESTS} new test functions/classes; "
fi

# Strip trailing separator
NEW_TEST_DETAILS=$(echo "$NEW_TEST_DETAILS" | sed 's/; $//')

# Determine result
if [[ "$NEW_TESTS_FOUND" -gt 0 ]]; then
  NEW_TESTS_WRITTEN=true
  NEW_TEST_EVIDENCE="$NEW_TESTS_FOUND new test methods ($NEW_TEST_DETAILS)"
else
  NEW_TESTS_WRITTEN=false
  NEW_TEST_EVIDENCE=""
fi

# Write to state
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

jq "
  .tasks |= map(if .id == \"$TASK_ID\" then
    .new_tests_written = $NEW_TESTS_WRITTEN |
    .new_test_evidence = \"$NEW_TEST_EVIDENCE\"
  else . end)
" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Task $TASK_ID new-test verification:"
if [[ "$NEW_TESTS_WRITTEN" == "true" ]]; then
  echo "  NEW TESTS: $NEW_TEST_EVIDENCE"
else
  echo "  WARNING: No new test methods detected in git diff"
  echo "  Agent may have only rerun existing tests without writing new ones"
fi

exit 0
