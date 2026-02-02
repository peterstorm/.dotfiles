#!/bin/bash
# Verify implementation agents wrote NEW tests (not just reran existing)
# Checks git diff for new test method patterns (@Test, it(, test(, describe()
# Only runs for implementation agents (skips reviewers)
# Sets new_tests_written + new_test_evidence in task state
#
# SCOPING: Uses files modified by THIS task (from transcript) to scope diff,
# preventing cumulative test counts when multiple tasks run in parallel.
# Supports cross-repo: finds task graph via session-scoped path if not in cwd

# Read hook input and extract transcript
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

# Resolve task graph path (supports cross-repo via session-scoped path)
source ~/.claude/hooks/helpers/resolve-task-graph.sh
TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
LOCK_FILE=$(task_graph_lock_file "$TASK_GRAPH")

source ~/.claude/hooks/helpers/parse-transcript.sh
source ~/.claude/hooks/helpers/parse-files-modified.sh
PROMPT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  PROMPT=$(parse_transcript "$TRANSCRIPT_PATH")
fi

# Extract task ID using flexible helper
source ~/.claude/hooks/helpers/extract-task-id.sh
TASK_ID=$(extract_task_id "$PROMPT")
[[ -z "$TASK_ID" ]] && exit 0

# Skip review agents — gate on agent field, not status (avoids ordering issues)
TASK_AGENT=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .agent" "$TASK_GRAPH")
case "$TASK_AGENT" in
  *review*|*reviewer*) exit 0 ;;
esac

# Skip if already verified as true (allow re-verification if false)
HAS_NEW_TESTS=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .new_tests_written // \"null\"" "$TASK_GRAPH")
[[ "$HAS_NEW_TESTS" == "true" ]] && exit 0

# Check if new tests are required for this task (default: true if field missing)
# Note: can't use // true because jq treats false as falsy
NEW_TESTS_REQUIRED=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .new_tests_required" "$TASK_GRAPH")
if [[ "$NEW_TESTS_REQUIRED" == "false" ]]; then
  source ~/.claude/hooks/helpers/lock.sh
  acquire_lock "$LOCK_FILE" auto
  jq "
    .tasks |= map(if .id == \"$TASK_ID\" then
      .new_tests_written = false |
      .new_test_evidence = \"new_tests_required=false (skipped)\"
    else . end)
  " "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"
  echo "Task $TASK_ID: new_tests_required=false, skipping verification"
  exit 0
fi

# --- Detect new test methods via git diff ---
# PRIMARY: Scope diff to files modified by THIS task (from transcript)
# FALLBACK: Use start_sha if no files found in transcript

FILES_MODIFIED=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  FILES_MODIFIED=$(parse_files_modified "$TRANSCRIPT_PATH")
fi

FULL_DIFF=""
USE_SHA_FALLBACK=false

if [[ -n "$FILES_MODIFIED" ]]; then
  # File-scoped diff: only files this task touched
  DIFF_UNSTAGED=$(echo "$FILES_MODIFIED" | xargs git diff -- 2>/dev/null)
  DIFF_STAGED=$(echo "$FILES_MODIFIED" | xargs git diff --cached -- 2>/dev/null)
  # Untracked files are invisible to git diff — use --no-index for new files
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
  # If file-scoped diff is empty (files already committed), fall back to SHA diff
  if [[ -z "$(echo "$FULL_DIFF" | tr -d '[:space:]')" ]]; then
    USE_SHA_FALLBACK=true
  fi
fi

if [[ -z "$FILES_MODIFIED" ]] || [[ "$USE_SHA_FALLBACK" == "true" ]]; then
  # Fallback: SHA-based diff (old behavior)
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

NEW_TESTS_FOUND=0
NEW_TEST_DETAILS=""

# Helper to safely count grep matches (returns clean integer)
count_matches() {
  local count
  count=$(echo "$1" | grep -cE "$2" 2>/dev/null || echo 0)
  count=${count//[^0-9]/}  # strip non-digits
  echo "${count:-0}"
}

# Java: @Test, @Property, @ParameterizedTest (new lines only)
JAVA_TESTS=$(count_matches "$FULL_DIFF" '^\+.*@(Test|Property|ParameterizedTest)\b')
if [[ "$JAVA_TESTS" -gt 0 ]]; then
  NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + JAVA_TESTS))
  NEW_TEST_DETAILS="${NEW_TEST_DETAILS}java: ${JAVA_TESTS} new @Test/@Property methods; "
fi

# TypeScript/JavaScript: it(, test(, describe( (new lines only)
TS_TESTS=$(count_matches "$FULL_DIFF" '^\+.*[[:space:]](it|test|describe)\(')
if [[ "$TS_TESTS" -gt 0 ]]; then
  NEW_TESTS_FOUND=$((NEW_TESTS_FOUND + TS_TESTS))
  NEW_TEST_DETAILS="${NEW_TEST_DETAILS}ts/js: ${TS_TESTS} new it/test/describe blocks; "
fi

# Python: def test_, class Test (new lines only)
PY_TESTS=$(count_matches "$FULL_DIFF" '^\+.*(def test_|class Test)')
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
if [[ -n "$FILES_MODIFIED" ]]; then
  FILE_COUNT=$(echo "$FILES_MODIFIED" | wc -l | tr -d ' ')
  echo "  Scope: $FILE_COUNT files from transcript"
else
  echo "  Scope: fallback (SHA-based diff)"
fi
if [[ "$NEW_TESTS_WRITTEN" == "true" ]]; then
  echo "  NEW TESTS: $NEW_TEST_EVIDENCE"
else
  echo "  WARNING: No new test methods detected in git diff"
  echo "  Agent may have only rerun existing tests without writing new ones"
fi

exit 0
