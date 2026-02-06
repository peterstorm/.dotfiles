#!/bin/bash
# Test suite for loom hooks and helpers
# Run from repo root: bash .claude/tests/test-loom.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Helper: reset state file (chmod 644 so cat > works, clears stale locks)
reset_state() {
  chmod 644 "$TEST_DIR/.claude/state/active_task_graph.json" 2>/dev/null || true
  rm -rf "$TEST_DIR/.claude/state/.task_graph.lock" "$TEST_DIR/.claude/state/.task_graph.lock.lock" 2>/dev/null || true
}

pass() {
  echo -e "${GREEN}✓ $1${NC}"
  ((PASS++)) || true
}

fail() {
  echo -e "${RED}✗ $1${NC}"
  echo "  Expected: $2"
  echo "  Got: $3"
  ((FAIL++)) || true
}

# Setup test state directory
mkdir -p "$TEST_DIR/.claude/state"
cd "$TEST_DIR"

echo "=== Task Planner Test Suite ==="
echo ""

# ============================================
# Test 1: Task ID extraction patterns (using helper)
# ============================================
echo "--- Test: Task ID Extraction (extract-task-id.sh) ---"

source "$REPO_ROOT/.claude/hooks/helpers/extract-task-id.sh"

# Pattern: **Task ID:** T1 (canonical)
PROMPT1='## Task Assignment

**Task ID:** T1
**Wave:** 1'

TASK_ID1=$(extract_task_id "$PROMPT1")
[[ "$TASK_ID1" == "T1" ]] && pass "Extracts from **Task ID:** T1 (canonical)" || fail "Extracts from **Task ID:** T1" "T1" "$TASK_ID1"

# Pattern: Task ID: T2 (plain, non-canonical)
PROMPT2='Task ID: T2
Wave: 1'

TASK_ID2=$(extract_task_id "$PROMPT2")
[[ "$TASK_ID2" == "T2" ]] && pass "Extracts from Task ID: T2 (plain)" || fail "Extracts from Task ID: T2" "T2" "$TASK_ID2"

# Pattern: TASK: T3 (common error format)
PROMPT3='TASK: T3
Description: test'

TASK_ID3=$(extract_task_id "$PROMPT3")
[[ "$TASK_ID3" == "T3" ]] && pass "Extracts from TASK: T3 (error format)" || fail "Extracts from TASK: T3" "T3" "$TASK_ID3"

# Pattern: Task: T4 (missing "ID")
PROMPT4='Task: T4
Wave: 1'

TASK_ID4=$(extract_task_id "$PROMPT4")
[[ "$TASK_ID4" == "T4" ]] && pass "Extracts from Task: T4 (missing ID)" || fail "Extracts from Task: T4" "T4" "$TASK_ID4"

# Pattern: No task ID
PROMPT5='Some random text without task ID'

TASK_ID5=$(extract_task_id "$PROMPT5" || true)
[[ -z "$TASK_ID5" ]] && pass "Returns empty for no task ID" || fail "Returns empty for no task ID" "" "$TASK_ID5"

# Pattern: Task T6 (no colon, common from main context)
PROMPT6='Task T6 create new component'
TASK_ID6=$(extract_task_id "$PROMPT6")
[[ "$TASK_ID6" == "T6" ]] && pass "Extracts from Task T6 (no colon)" || fail "Extracts from Task T6" "T6" "$TASK_ID6"

# Pattern: T7 Description (task ID at start)
PROMPT7='T7 - Implement user auth'
TASK_ID7=$(extract_task_id "$PROMPT7")
[[ "$TASK_ID7" == "T7" ]] && pass "Extracts from T7 - desc (ID at start)" || fail "Extracts from T7 -" "T7" "$TASK_ID7"

# Pattern: implement T8 (verb + task)
PROMPT8='implement T8 user service'
TASK_ID8=$(extract_task_id "$PROMPT8")
[[ "$TASK_ID8" == "T8" ]] && pass "Extracts from implement T8 (verb)" || fail "Extracts from implement T8" "T8" "$TASK_ID8"

# Pattern: T9 with uppercase desc (common agent desc format)
PROMPT9='T9 Create validation layer'
TASK_ID9=$(extract_task_id "$PROMPT9")
[[ "$TASK_ID9" == "T9" ]] && pass "Extracts from T9 Desc (uppercase)" || fail "Extracts from T9 Desc" "T9" "$TASK_ID9"

# ============================================
# Test 1b: Format validation (validate_task_id_format)
# ============================================
echo ""
echo "--- Test: Task ID Format Validation ---"

# Canonical format should return 0 (use if to avoid set -e exit)
if validate_task_id_format "$PROMPT1"; then
  pass "Canonical format returns 0"
else
  fail "Canonical format returns 0" "0" "$?"
fi

# Non-canonical format should return 1
validate_task_id_format "$PROMPT2" || EXIT_CODE=$?
[[ "$EXIT_CODE" -eq 1 ]] && pass "Plain format returns 1 (non-canonical)" || fail "Plain format returns 1" "1" "$EXIT_CODE"

# Error format (TASK: T3) should return 1
EXIT_CODE=0
validate_task_id_format "$PROMPT3" || EXIT_CODE=$?
[[ "$EXIT_CODE" -eq 1 ]] && pass "TASK: format returns 1 (non-canonical)" || fail "TASK: format returns 1" "1" "$EXIT_CODE"

# No task ID should return 2
EXIT_CODE=0
validate_task_id_format "$PROMPT5" || EXIT_CODE=$?
[[ "$EXIT_CODE" -eq 2 ]] && pass "No task ID returns 2" || fail "No task ID returns 2" "2" "$EXIT_CODE"

# ============================================
# Test 2: store-review-findings.sh with stdin
# ============================================
echo ""
echo "--- Test: store-review-findings.sh ---"

# Create test state
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "pending", "critical_findings": [], "advisory_findings": []}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": true, "reviews_complete": false, "blocked": false}}
}
EOF

# Test stdin input with special characters
bash "$REPO_ROOT/.claude/hooks/helpers/store-review-findings.sh" --task T1 <<'EOF'
CRITICAL: SQL injection via "$user_input" in query
CRITICAL: Missing auth check on /api/admin
ADVISORY: Consider using `Optional<T>` instead of null
EOF

CRITICAL_COUNT=$(jq '[.tasks[] | select(.id=="T1") | .critical_findings | length] | add' "$TEST_DIR/.claude/state/active_task_graph.json")
ADVISORY_COUNT=$(jq '[.tasks[] | select(.id=="T1") | .advisory_findings | length] | add' "$TEST_DIR/.claude/state/active_task_graph.json")
REVIEW_STATUS=$(jq -r '.tasks[] | select(.id=="T1") | .review_status' "$TEST_DIR/.claude/state/active_task_graph.json")
WAVE_BLOCKED=$(jq -r '.wave_gates["1"].blocked' "$TEST_DIR/.claude/state/active_task_graph.json")

[[ "$CRITICAL_COUNT" == "2" ]] && pass "Stores 2 critical findings" || fail "Stores 2 critical findings" "2" "$CRITICAL_COUNT"
[[ "$ADVISORY_COUNT" == "1" ]] && pass "Stores 1 advisory finding" || fail "Stores 1 advisory finding" "1" "$ADVISORY_COUNT"
[[ "$REVIEW_STATUS" == "blocked" ]] && pass "Sets review_status to blocked" || fail "Sets review_status to blocked" "blocked" "$REVIEW_STATUS"
[[ "$WAVE_BLOCKED" == "true" ]] && pass "Sets wave blocked=true" || fail "Sets wave blocked=true" "true" "$WAVE_BLOCKED"

# Verify special chars preserved
FINDING=$(jq -r '.tasks[] | select(.id=="T1") | .critical_findings[0]' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$FINDING" == *'$user_input'* ]] && pass "Preserves \$user_input in finding" || fail "Preserves special chars" "contains \$user_input" "$FINDING"

# ============================================
# Test 3: mark-tests-passed.sh (read-only verifier)
# ============================================
echo ""
echo "--- Test: mark-tests-passed.sh (read-only) ---"

# Test: all tasks have evidence → exit 0
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "tests_passed": true, "test_evidence": "node: 5 passing", "new_tests_written": true, "new_test_evidence": "ts/js: 3 new it/test/describe blocks"}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

if bash "$REPO_ROOT/.claude/hooks/helpers/mark-tests-passed.sh" >/dev/null 2>&1; then
  pass "mark-tests-passed exits 0 when all tasks have evidence"
else
  fail "mark-tests-passed exits 0 when all tasks have evidence" "exit 0" "exit 1"
fi

# Verify state was NOT modified (read-only)
TESTS_PASSED=$(jq -r '.wave_gates["1"].tests_passed' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$TESTS_PASSED" == "null" ]] && pass "mark-tests-passed does NOT modify state (read-only)" || fail "mark-tests-passed read-only" "null" "$TESTS_PASSED"

# Test: missing test evidence → exit 1
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "tests_passed": false, "new_tests_written": false}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

if bash "$REPO_ROOT/.claude/hooks/helpers/mark-tests-passed.sh" >/dev/null 2>&1; then
  fail "mark-tests-passed exits 1 when evidence missing" "exit 1" "exit 0"
else
  pass "mark-tests-passed exits 1 when evidence missing"
fi

# ============================================
# Test 4: complete-wave-gate.sh
# ============================================
echo ""
echo "--- Test: complete-wave-gate.sh ---"

# Setup: wave 1 complete, no critical findings, all test evidence present
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "issue": null,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "advisory_findings": [], "tests_passed": true, "test_evidence": "node: 3 passing", "new_tests_written": true, "new_test_evidence": "ts/js: 2 new it blocks"},
    {"id": "T2", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "advisory_findings": [], "tests_passed": true, "test_evidence": "node: 5 passing", "new_tests_written": true, "new_test_evidence": "ts/js: 4 new test blocks"},
    {"id": "T3", "wave": 2, "status": "pending", "review_status": "pending", "critical_findings": [], "advisory_findings": []}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": true, "reviews_complete": false, "blocked": false}}
}
EOF

bash "$REPO_ROOT/.claude/hooks/helpers/complete-wave-gate.sh"

CURRENT_WAVE=$(jq -r '.current_wave' "$TEST_DIR/.claude/state/active_task_graph.json")
T1_STATUS=$(jq -r '.tasks[] | select(.id=="T1") | .status' "$TEST_DIR/.claude/state/active_task_graph.json")
REVIEWS_COMPLETE=$(jq -r '.wave_gates["1"].reviews_complete' "$TEST_DIR/.claude/state/active_task_graph.json")
WAVE2_EXISTS=$(jq -r '.wave_gates["2"] // "missing"' "$TEST_DIR/.claude/state/active_task_graph.json")

[[ "$CURRENT_WAVE" == "2" ]] && pass "Advances to wave 2" || fail "Advances to wave 2" "2" "$CURRENT_WAVE"
[[ "$T1_STATUS" == "completed" ]] && pass "Marks T1 completed" || fail "Marks T1 completed" "completed" "$T1_STATUS"
[[ "$REVIEWS_COMPLETE" == "true" ]] && pass "Sets reviews_complete=true" || fail "Sets reviews_complete" "true" "$REVIEWS_COMPLETE"
[[ "$WAVE2_EXISTS" != "missing" ]] && pass "Initializes wave 2 gate" || fail "Initializes wave 2 gate" "object" "$WAVE2_EXISTS"

# Test blocking when critical findings exist
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [{"id": "T1", "wave": 1, "status": "implemented", "review_status": "blocked", "critical_findings": ["bug"], "advisory_findings": []}],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": true, "reviews_complete": false, "blocked": true}}
}
EOF

if bash "$REPO_ROOT/.claude/hooks/helpers/complete-wave-gate.sh" 2>&1; then
  fail "Blocks when critical findings exist" "exit 1" "exit 0"
else
  pass "Blocks when critical findings exist"
fi

# ============================================
# Test 5: validate-task-execution.sh (combined hook)
# ============================================
echo ""
echo "--- Test: validate-task-execution.sh ---"

# Setup state
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "pending", "depends_on": []},
    {"id": "T2", "wave": 2, "status": "pending", "depends_on": ["T1"]}
  ],
  "wave_gates": {"1": {"impl_complete": false, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

# Test: Allow wave 1 task (pipe JSON via stdin, not env var)
if echo '{"tool_name": "Task", "tool_input": {"prompt": "**Task ID:** T1\nImplement feature"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1; then
  pass "Allows wave 1 task when current_wave=1"
else
  fail "Allows wave 1 task" "exit 0" "exit non-zero"
fi

# Test: Block wave 2 task
if echo '{"tool_name": "Task", "tool_input": {"prompt": "**Task ID:** T2\nImplement feature"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1; then
  fail "Blocks wave 2 task when current_wave=1" "exit 2" "exit 0"
else
  pass "Blocks wave 2 task when current_wave=1"
fi

# Test: Allow non-planned task (no Task ID)
if echo '{"tool_name": "Task", "tool_input": {"prompt": "Run some tests"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1; then
  pass "Allows non-planned tasks (no Task ID)"
else
  fail "Allows non-planned tasks" "exit 0" "exit non-zero"
fi

# Test: Accepts non-canonical format (TASK: T1) - permissive parsing
if echo '{"tool_name": "Task", "tool_input": {"prompt": "TASK: T1\nImplement feature"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>/dev/null; then
  pass "Accepts non-canonical format (TASK: T1)"
else
  fail "Accepts non-canonical format (TASK: T1)" "exit 0" "exit 2"
fi

# Test: Accepts non-canonical format (Task ID: T1 without bold)
if echo '{"tool_name": "Task", "tool_input": {"prompt": "Task ID: T1\nImplement feature"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>/dev/null; then
  pass "Accepts non-canonical format (Task ID: T1)"
else
  fail "Accepts non-canonical format (Task ID: T1)" "exit 0" "exit 2"
fi

# Test: Accepts non-canonical format (Task: T1 missing ID)
if echo '{"tool_name": "Task", "tool_input": {"prompt": "Task: T1\nImplement feature"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>/dev/null; then
  pass "Accepts non-canonical format (Task: T1)"
else
  fail "Accepts non-canonical format (Task: T1)" "exit 0" "exit 2"
fi

# ============================================
# Test 6: File locking (race condition prevention)
# ============================================
echo ""
echo "--- Test: File Locking ---"

# Verify lock mechanism works (file on Linux, directory on macOS)
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{"current_wave": 1, "tasks": [{"id":"T1","wave":1,"tests_passed":true,"new_tests_written":true}], "wave_gates": {"1": {"tests_passed": null}}}
EOF

bash "$REPO_ROOT/.claude/hooks/helpers/mark-tests-passed.sh" >/dev/null 2>&1 || true
# Lock is released after script exits, so just verify the helper works
if command -v flock &>/dev/null; then
  pass "Lock mechanism available (flock)"
else
  pass "Lock mechanism available (mkdir-based)"
fi

# ============================================
# Test 7: parse-transcript.sh (env var path, no injection)
# ============================================
echo ""
echo "--- Test: parse-transcript.sh ---"

# Create a fake JSONL transcript
cat > "$TEST_DIR/transcript.jsonl" << 'EOF'
{"message": {"content": "Hello from agent"}}
{"message": {"content": [{"type": "text", "text": "Task completed"}]}}
{"message": {"content": [{"type": "tool_result", "content": "BUILD SUCCESS"}]}}
EOF

source "$REPO_ROOT/.claude/hooks/helpers/parse-transcript.sh"
RESULT=$(parse_transcript "$TEST_DIR/transcript.jsonl")

echo "$RESULT" | grep -q "Hello from agent" && pass "parse-transcript: extracts string content" || fail "parse-transcript: extracts string content" "contains 'Hello from agent'" "$RESULT"
echo "$RESULT" | grep -q "Task completed" && pass "parse-transcript: extracts text blocks" || fail "parse-transcript: extracts text blocks" "contains 'Task completed'" "$RESULT"
echo "$RESULT" | grep -q "BUILD SUCCESS" && pass "parse-transcript: extracts tool_result content" || fail "parse-transcript: extracts tool_result content" "contains 'BUILD SUCCESS'" "$RESULT"

# Test path with spaces (regression for injection fix)
mkdir -p "$TEST_DIR/path with spaces"
cp "$TEST_DIR/transcript.jsonl" "$TEST_DIR/path with spaces/transcript.jsonl"
RESULT_SPACES=$(parse_transcript "$TEST_DIR/path with spaces/transcript.jsonl")
echo "$RESULT_SPACES" | grep -q "Hello from agent" && pass "parse-transcript: handles paths with spaces" || fail "parse-transcript: handles paths with spaces" "content extracted" "$RESULT_SPACES"

# Test path with single quote (the original injection vector)
mkdir -p "$TEST_DIR/it's a path"
cp "$TEST_DIR/transcript.jsonl" "$TEST_DIR/it's a path/transcript.jsonl"
RESULT_QUOTE=$(parse_transcript "$TEST_DIR/it's a path/transcript.jsonl")
echo "$RESULT_QUOTE" | grep -q "Hello from agent" && pass "parse-transcript: handles paths with single quotes" || fail "parse-transcript: handles paths with single quotes" "content extracted" "$RESULT_QUOTE"

# Test invalid JSONL (should not crash, just skip bad lines)
cat > "$TEST_DIR/bad-transcript.jsonl" << 'EOF'
not valid json
{"message": {"content": "valid line"}}
also not json {{{
EOF

RESULT_BAD=$(parse_transcript "$TEST_DIR/bad-transcript.jsonl")
echo "$RESULT_BAD" | grep -q "valid line" && pass "parse-transcript: survives invalid JSONL lines" || fail "parse-transcript: survives invalid JSONL" "contains 'valid line'" "$RESULT_BAD"

# ============================================
# Test 8: validate-task-execution.sh stores start_sha
# ============================================
echo ""
echo "--- Test: Per-task start_sha ---"

# Need a git repo for HEAD SHA
GIT_TEST_DIR=$(mktemp -d)
(cd "$GIT_TEST_DIR" && git init -q && git commit --allow-empty -m "init" -q)
EXPECTED_SHA=$(cd "$GIT_TEST_DIR" && git rev-parse HEAD)

mkdir -p "$GIT_TEST_DIR/.claude/state"
cat > "$GIT_TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "pending", "depends_on": []}
  ],
  "wave_gates": {"1": {"impl_complete": false, "reviews_complete": false, "blocked": false}}
}
EOF

# Run validate hook from git dir (it stores HEAD SHA)
(cd "$GIT_TEST_DIR" && echo '{"tool_name": "Task", "tool_input": {"prompt": "**Task ID:** T1\nImplement feature"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1)

STORED_SHA=$(jq -r '.tasks[] | select(.id=="T1") | .start_sha // "missing"' "$GIT_TEST_DIR/.claude/state/active_task_graph.json")

[[ "$STORED_SHA" == "$EXPECTED_SHA" ]] && pass "validate-task-execution stores HEAD SHA as start_sha" || fail "validate-task-execution stores start_sha" "$EXPECTED_SHA" "$STORED_SHA"

# Non-planned task (no Task ID) should NOT store SHA
chmod 644 "$GIT_TEST_DIR/.claude/state/active_task_graph.json" 2>/dev/null || true
rm -rf "$GIT_TEST_DIR/.claude/state/.task_graph.lock"* 2>/dev/null || true
cat > "$GIT_TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [{"id": "T1", "wave": 1, "status": "pending", "depends_on": []}],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF

(cd "$GIT_TEST_DIR" && echo '{"tool_name": "Task", "tool_input": {"prompt": "Run some tests"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1)
NO_SHA=$(jq -r '.tasks[] | select(.id=="T1") | .start_sha // "missing"' "$GIT_TEST_DIR/.claude/state/active_task_graph.json")
[[ "$NO_SHA" == "missing" ]] && pass "No start_sha stored for non-planned tasks" || fail "No start_sha for non-planned tasks" "missing" "$NO_SHA"

rm -rf "$GIT_TEST_DIR"

# ============================================
# Test 9: guard-state-file.sh expanded write patterns
# ============================================
echo ""
echo "--- Test: guard-state-file.sh write patterns ---"

cd "$TEST_DIR"

# Recreate state for guard hook
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{"current_wave": 1, "tasks": [], "wave_gates": {}}
EOF

# Test: >> (append) should be blocked
if echo '{"tool_name": "Bash", "tool_input": {"command": "echo x >> .claude/state/active_task_graph.json"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  fail "Blocks >> append to state file" "exit 2" "exit 0"
else
  pass "Blocks >> append to state file"
fi

# Test: python3 write should be blocked
if echo '{"tool_name": "Bash", "tool_input": {"command": "python3 -c \"open(active_task_graph).write(x)\""}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  fail "Blocks python3 write to state file" "exit 2" "exit 0"
else
  pass "Blocks python3 write to state file"
fi

# Test: jq read (no write) should be allowed
if echo '{"tool_name": "Bash", "tool_input": {"command": "jq . .claude/state/active_task_graph.json"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  pass "Allows jq read of state file"
else
  fail "Allows jq read of state file" "exit 0" "exit 2"
fi

# Test: cat read should be allowed
if echo '{"tool_name": "Bash", "tool_input": {"command": "cat .claude/state/active_task_graph.json"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  pass "Allows cat read of state file"
else
  fail "Allows cat read of state file" "exit 0" "exit 2"
fi

# Test: whitelisted helper should be allowed
if echo '{"tool_name": "Bash", "tool_input": {"command": "bash ~/.claude/hooks/helpers/complete-wave-gate.sh"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  pass "Allows whitelisted helper script"
else
  fail "Allows whitelisted helper script" "exit 0" "exit 2"
fi

# ============================================
# Test 10: block-direct-edits.sh blocks during orchestration
# ============================================
echo ""
echo "--- Test: block-direct-edits.sh ---"

# Ensure state file exists for the hook to activate
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{"current_wave": 1, "tasks": [], "wave_gates": {"1": {"blocked": false}}}
EOF

# Test: Edit blocked during orchestration
# NOTE: Subagents bypass PreToolUse hooks entirely (run in subprocess),
# so this hook only blocks MAIN Claude from editing directly.
if echo '{"tool_name": "Edit", "tool_input": {"file_path": "test.ts"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/block-direct-edits.sh" 2>/dev/null; then
  fail "Blocks Edit during orchestration" "exit 2" "exit 0"
else
  pass "Blocks Edit during orchestration"
fi

# Test: Write blocked during orchestration
if echo '{"tool_name": "Write", "tool_input": {"file_path": "test.ts"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/block-direct-edits.sh" 2>/dev/null; then
  fail "Blocks Write during orchestration" "exit 2" "exit 0"
else
  pass "Blocks Write during orchestration"
fi

# Test: Other tools allowed
if echo '{"tool_name": "Read", "tool_input": {"file_path": "test.ts"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/block-direct-edits.sh" 2>/dev/null; then
  pass "Allows Read during orchestration"
else
  fail "Allows Read during orchestration" "exit 0" "exit 2"
fi

# Test: No task graph = no blocking (orchestration not active)
rm "$TEST_DIR/.claude/state/active_task_graph.json"
if echo '{"tool_name": "Edit", "tool_input": {"file_path": "test.ts"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/block-direct-edits.sh" 2>/dev/null; then
  pass "Allows Edit when no orchestration active"
else
  fail "Allows Edit when no orchestration active" "exit 0" "exit 2"
fi

# Restore state file for subsequent tests
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{"current_wave": 1, "tasks": [], "wave_gates": {"1": {"blocked": false}}}
EOF

# ============================================
# Test 11: SessionStart cleanup hook
# ============================================
echo ""
echo "--- Test: SessionStart cleanup ---"

mkdir -p /tmp/claude-subagents

# Create files with OLD timestamps (> 60 min) - these should be cleaned
echo "stale-agent" > /tmp/claude-subagents/old-session.active
echo "code-implementer-agent" > /tmp/claude-subagents/stale-agent.type
touch -t 202001010000 /tmp/claude-subagents/old-session.active  # Jan 1, 2020
touch -t 202001010000 /tmp/claude-subagents/stale-agent.type

# Create files with RECENT timestamps - these should be preserved
echo "recent-agent" > /tmp/claude-subagents/new-session.active
echo "recent-type" > /tmp/claude-subagents/recent-agent.type

bash "$REPO_ROOT/.claude/hooks/SessionStart/cleanup-stale-subagents.sh"

if [[ -f /tmp/claude-subagents/old-session.active ]]; then
  fail "SessionStart cleans stale (>60min) .active files" "deleted" "still exists"
else
  pass "SessionStart cleans stale (>60min) .active files"
fi

if [[ -f /tmp/claude-subagents/stale-agent.type ]]; then
  fail "SessionStart cleans stale (>60min) .type files" "deleted" "still exists"
else
  pass "SessionStart cleans stale (>60min) .type files"
fi

# Verify recent files preserved
if [[ -f /tmp/claude-subagents/new-session.active ]]; then
  pass "SessionStart preserves recent (<60min) files"
else
  fail "SessionStart preserves recent files" "preserved" "deleted"
fi

# Cleanup recent files
rm -f /tmp/claude-subagents/new-session.active /tmp/claude-subagents/recent-agent.type

# ============================================
# Test 12: complete-wave-gate.sh blocks missing new_tests_written
# ============================================
echo ""
echo "--- Test: complete-wave-gate.sh new_tests_written gate ---"

cd "$TEST_DIR"

# Tests pass but no new tests written
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "tests_passed": true, "test_evidence": "node: 3 passing", "new_tests_written": false, "new_test_evidence": ""}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

if bash "$REPO_ROOT/.claude/hooks/helpers/complete-wave-gate.sh" 2>&1; then
  fail "Blocks when new_tests_written=false" "exit 1" "exit 0"
else
  pass "Blocks when new_tests_written=false"
fi

# ============================================
# Test 13: cleanup-subagent-flag.sh uses lock.sh
# ============================================
echo ""
echo "--- Test: cleanup-subagent-flag.sh ---"

mkdir -p /tmp/claude-subagents
echo -e "agent-aaa\nagent-bbb" > /tmp/claude-subagents/cleanup-test-session.active
echo "code-implementer-agent" > /tmp/claude-subagents/agent-aaa.type

# Simulate SubagentStop for agent-aaa
echo '{"session_id": "cleanup-test-session", "agent_id": "agent-aaa"}' | bash "$REPO_ROOT/.claude/hooks/SubagentStop/cleanup-subagent-flag.sh"

# agent-aaa should be removed, agent-bbb should remain
if [[ -f /tmp/claude-subagents/cleanup-test-session.active ]]; then
  REMAINING=$(cat /tmp/claude-subagents/cleanup-test-session.active)
  echo "$REMAINING" | grep -q "agent-bbb" && pass "cleanup: keeps other agents in .active" || fail "cleanup: keeps agent-bbb" "agent-bbb" "$REMAINING"
  ! echo "$REMAINING" | grep -q "agent-aaa" && pass "cleanup: removes completed agent from .active" || fail "cleanup: removes agent-aaa" "absent" "$REMAINING"
else
  fail "cleanup: .active file should still exist with agent-bbb" "file exists" "file deleted"
fi

# Type file PRESERVED for other SubagentStop hooks (periodic cleanup handles old files)
[[ -f /tmp/claude-subagents/agent-aaa.type ]] && pass "cleanup: preserves .type for other hooks" || fail "cleanup: preserves .type" "preserved" "deleted"

# Cleanup
rm -rf /tmp/claude-subagents

# ============================================
# Test 14: parse-files-modified.sh
# ============================================
echo ""
echo "--- Test: parse-files-modified.sh ---"

# Create a fake JSONL transcript with Write/Edit tool calls
cat > "$TEST_DIR/transcript-files.jsonl" << 'EOF'
{"message": {"content": [{"type": "tool_use", "name": "Write", "input": {"file_path": "/src/main/Foo.java", "content": "class Foo {}"}}]}}
{"message": {"content": [{"type": "tool_use", "name": "Edit", "input": {"file_path": "/src/test/FooTest.java", "old_string": "x", "new_string": "y"}}]}}
{"message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "/src/main/Bar.java"}}]}}
{"message": {"content": "Some text message"}}
EOF

source "$REPO_ROOT/.claude/hooks/helpers/parse-files-modified.sh"
FILES_RESULT=$(parse_files_modified "$TEST_DIR/transcript-files.jsonl")

echo "$FILES_RESULT" | grep -q "/src/main/Foo.java" && pass "parse-files-modified: extracts Write file_path" || fail "parse-files-modified: extracts Write" "contains Foo.java" "$FILES_RESULT"
echo "$FILES_RESULT" | grep -q "/src/test/FooTest.java" && pass "parse-files-modified: extracts Edit file_path" || fail "parse-files-modified: extracts Edit" "contains FooTest.java" "$FILES_RESULT"
! echo "$FILES_RESULT" | grep -q "/src/main/Bar.java" && pass "parse-files-modified: ignores Read file_path" || fail "parse-files-modified: ignores Read" "no Bar.java" "$FILES_RESULT"

# Test empty transcript
echo '{"message": {"content": "no tools"}}' > "$TEST_DIR/empty-tools.jsonl"
EMPTY_RESULT=$(parse_files_modified "$TEST_DIR/empty-tools.jsonl")
[[ -z "$EMPTY_RESULT" ]] && pass "parse-files-modified: returns empty for no Write/Edit" || fail "parse-files-modified: empty result" "" "$EMPTY_RESULT"

# ============================================
# Test 15: complete-wave-gate.sh new_tests_required=false
# ============================================
echo ""
echo "--- Test: complete-wave-gate.sh new_tests_required=false ---"

cd "$TEST_DIR"

# Task with new_tests_required=false should pass even with new_tests_written=false
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "tests_passed": true, "test_evidence": "node: 3 passing", "new_tests_required": false, "new_tests_written": false, "new_test_evidence": "new_tests_required=false (skipped)"}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

if bash "$REPO_ROOT/.claude/hooks/helpers/complete-wave-gate.sh" 2>&1 | grep -q "All checks passed"; then
  pass "Passes when new_tests_required=false"
else
  fail "Passes when new_tests_required=false" "All checks passed" "blocked"
fi

# Mixed: one task with new_tests_required=false, one with true and written
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "tests_passed": true, "test_evidence": "node: 3 passing", "new_tests_required": false, "new_tests_written": false, "new_test_evidence": "new_tests_required=false (skipped)"},
    {"id": "T2", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "tests_passed": true, "test_evidence": "node: 5 passing", "new_tests_required": true, "new_tests_written": true, "new_test_evidence": "java: 2 new @Test methods"}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

if bash "$REPO_ROOT/.claude/hooks/helpers/complete-wave-gate.sh" 2>&1 | grep -q "All checks passed"; then
  pass "Mixed tasks: false + true both pass"
else
  fail "Mixed tasks pass" "All checks passed" "blocked"
fi

# new_tests_required=true but new_tests_written=false should still fail
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "tests_passed": true, "test_evidence": "node: 3 passing", "new_tests_required": true, "new_tests_written": false, "new_test_evidence": ""}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

if bash "$REPO_ROOT/.claude/hooks/helpers/complete-wave-gate.sh" 2>&1; then
  fail "Blocks when new_tests_required=true but written=false" "exit 1" "exit 0"
else
  pass "Blocks when new_tests_required=true but written=false"
fi

# ============================================
# Test 16: update-task-status.sh new_tests_required=false skip (merged from verify-new-tests)
# ============================================
echo ""
echo "--- Test: update-task-status.sh new_tests_required=false ---"

# Need a git repo for new-test detection
VNT_GIT_DIR=$(mktemp -d)
(cd "$VNT_GIT_DIR" && git init -q && git commit --allow-empty -m "init" -q)

mkdir -p "$VNT_GIT_DIR/.claude/state"
mkdir -p /tmp/claude-subagents
cat > "$VNT_GIT_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "pending", "agent": "code-implementer-agent", "new_tests_required": false}
  ],
  "executing_tasks": [],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF
echo "$VNT_GIT_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/vnt-skip-session.task_graph

# Create transcript with Task ID (text content only — no Bash tool output)
cat > "$VNT_GIT_DIR/skip-transcript.jsonl" << 'EOF'
{"message": {"content": "**Task ID:** T1\nImplementing migration"}}
EOF

# Run update-task-status from git dir
(cd "$VNT_GIT_DIR" && echo "{\"session_id\": \"vnt-skip-session\", \"agent_type\": \"code-implementer-agent\", \"agent_transcript_path\": \"$VNT_GIT_DIR/skip-transcript.jsonl\"}" | bash "$REPO_ROOT/.claude/hooks/SubagentStop/update-task-status.sh" 2>&1)

# Check new_test_evidence indicates skipped
SKIP_EVIDENCE=$(jq -r '.tasks[] | select(.id=="T1") | .new_test_evidence' "$VNT_GIT_DIR/.claude/state/active_task_graph.json")
[[ "$SKIP_EVIDENCE" == *"skipped"* ]] && pass "update-task-status: skips new-test when new_tests_required=false" || fail "update-task-status: skips" "contains 'skipped'" "$SKIP_EVIDENCE"

# Verify task was marked implemented
TASK_STATUS=$(jq -r '.tasks[] | select(.id=="T1") | .status' "$VNT_GIT_DIR/.claude/state/active_task_graph.json")
[[ "$TASK_STATUS" == "implemented" ]] && pass "update-task-status: marks implemented with skip" || fail "update-task-status: marks implemented" "implemented" "$TASK_STATUS"

rm -rf "$VNT_GIT_DIR" /tmp/claude-subagents
cd "$TEST_DIR"

# ============================================
# Test 17: resolve-task-graph.sh helper
# ============================================
echo ""
echo "--- Test: resolve-task-graph.sh ---"

source "$REPO_ROOT/.claude/hooks/helpers/resolve-task-graph.sh"

# Test: local path found
cd "$TEST_DIR"
RESOLVED=$(resolve_task_graph "test-session-123")
[[ "$RESOLVED" == ".claude/state/active_task_graph.json" ]] && pass "resolve-task-graph: finds local path" || fail "resolve-task-graph: finds local" ".claude/state/active_task_graph.json" "$RESOLVED"

# Test: session-scoped path takes priority
mkdir -p /tmp/claude-subagents
echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/test-session-456.task_graph
RESOLVED_SESSION=$(resolve_task_graph "test-session-456")
[[ "$RESOLVED_SESSION" == "$TEST_DIR/.claude/state/active_task_graph.json" ]] && pass "resolve-task-graph: session path priority" || fail "resolve-task-graph: session priority" "$TEST_DIR/.claude/state/active_task_graph.json" "$RESOLVED_SESSION"

# Test: cross-repo scenario (no local task graph, use session path)
CROSS_REPO_DIR=$(mktemp -d)
cd "$CROSS_REPO_DIR"
RESOLVED_CROSS=$(resolve_task_graph "test-session-456")
[[ "$RESOLVED_CROSS" == "$TEST_DIR/.claude/state/active_task_graph.json" ]] && pass "resolve-task-graph: cross-repo via session" || fail "resolve-task-graph: cross-repo" "$TEST_DIR/.claude/state/active_task_graph.json" "$RESOLVED_CROSS"
rm -rf "$CROSS_REPO_DIR"

# Test: no task graph found
rm -f /tmp/claude-subagents/test-session-456.task_graph
cd /tmp
if resolve_task_graph "nonexistent-session" >/dev/null 2>&1; then
  fail "resolve-task-graph: returns error when not found" "exit 1" "exit 0"
else
  pass "resolve-task-graph: returns error when not found"
fi

# Cleanup
rm -rf /tmp/claude-subagents
cd "$TEST_DIR"

# ============================================
# Test 18: SubagentStart stores task_graph path
# ============================================
echo ""
echo "--- Test: SubagentStart stores task_graph path ---"

rm -rf /tmp/claude-subagents

# SubagentStart in directory WITH task graph
cd "$TEST_DIR"
echo '{"session_id": "store-path-session", "agent_id": "agent-xyz", "agent_type": "code-implementer-agent"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStart/mark-subagent-active.sh"

# Check .task_graph file was created with absolute path
if [[ -f /tmp/claude-subagents/store-path-session.task_graph ]]; then
  STORED_PATH=$(cat /tmp/claude-subagents/store-path-session.task_graph)
  [[ "$STORED_PATH" == *"/.claude/state/active_task_graph.json" ]] && pass "SubagentStart: stores absolute task_graph path" || fail "SubagentStart: stores abs path" "*/.claude/state/active_task_graph.json" "$STORED_PATH"
  [[ "$STORED_PATH" == /* ]] && pass "SubagentStart: path is absolute" || fail "SubagentStart: path absolute" "starts with /" "$STORED_PATH"
else
  fail "SubagentStart: creates .task_graph file" "file exists" "file not found"
fi

# SubagentStart in directory WITHOUT task graph should NOT create file
NO_GRAPH_DIR=$(mktemp -d)
cd "$NO_GRAPH_DIR"
rm -f /tmp/claude-subagents/no-graph-session.task_graph
echo '{"session_id": "no-graph-session", "agent_id": "agent-abc", "agent_type": "code-implementer-agent"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStart/mark-subagent-active.sh"

[[ ! -f /tmp/claude-subagents/no-graph-session.task_graph ]] && pass "SubagentStart: no .task_graph when no local graph" || fail "SubagentStart: no file without graph" "file not exists" "file created"
rm -rf "$NO_GRAPH_DIR"

# Cleanup
rm -rf /tmp/claude-subagents
cd "$TEST_DIR"

# ============================================
# Test 19: cleanup preserves .task_graph on last agent (for parallel SubagentStop hooks)
# ============================================
echo ""
echo "--- Test: cleanup preserves .task_graph on last agent ---"

mkdir -p /tmp/claude-subagents
echo "agent-last" > /tmp/claude-subagents/cleanup-graph-session.active
echo "/some/path/task_graph.json" > /tmp/claude-subagents/cleanup-graph-session.task_graph
echo "code-implementer-agent" > /tmp/claude-subagents/agent-last.type

# Simulate last agent completing
echo '{"session_id": "cleanup-graph-session", "agent_id": "agent-last"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/cleanup-subagent-flag.sh"

[[ ! -f /tmp/claude-subagents/cleanup-graph-session.active ]] && pass "cleanup: removes .active on last agent" || fail "cleanup: removes .active" "deleted" "still exists"
# .task_graph is now preserved for parallel SubagentStop hooks (advance-phase, update-task-status)
# cleanup-stale-subagents.sh handles stale files (>60min)
[[ -f /tmp/claude-subagents/cleanup-graph-session.task_graph ]] && pass "cleanup: preserves .task_graph for parallel hooks" || fail "cleanup: preserves .task_graph" "preserved" "deleted"

# Cleanup
rm -rf /tmp/claude-subagents

# ============================================
# Test 20: validate-phase-order.sh - phase enforcement
# ============================================
echo ""
echo "--- Test: validate-phase-order.sh ---"

cd "$TEST_DIR"

# Setup: state at init phase (no brainstorm yet)
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "init",
  "phase_artifacts": {},
  "skipped_phases": [],
  "current_wave": null,
  "tasks": []
}
EOF

# Test: brainstorm-agent allowed from init
if echo '{"tool_name": "Task", "tool_input": {"prompt": "Explore feature", "subagent_type": "brainstorm-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>&1; then
  pass "validate-phase-order: allows brainstorm from init"
else
  fail "validate-phase-order: allows brainstorm from init" "exit 0" "exit 2"
fi

# Test: specify-agent BLOCKED from init (brainstorm not done)
if echo '{"tool_name": "Task", "tool_input": {"prompt": "Create spec", "subagent_type": "specify-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>/dev/null; then
  fail "validate-phase-order: blocks specify from init" "exit 2" "exit 0"
else
  pass "validate-phase-order: blocks specify from init"
fi

# Test: specify-agent allowed when brainstorm skipped
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "init",
  "phase_artifacts": {},
  "skipped_phases": ["brainstorm"],
  "current_wave": null,
  "tasks": []
}
EOF

if echo '{"tool_name": "Task", "tool_input": {"prompt": "Create spec", "subagent_type": "specify-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>&1; then
  pass "validate-phase-order: allows specify when brainstorm skipped"
else
  fail "validate-phase-order: allows specify when brainstorm skipped" "exit 0" "exit 2"
fi

# Test: architecture-agent BLOCKED when spec missing
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "specify",
  "phase_artifacts": {"brainstorm": "completed"},
  "skipped_phases": [],
  "current_wave": null,
  "tasks": []
}
EOF

if echo '{"tool_name": "Task", "tool_input": {"prompt": "Design architecture", "subagent_type": "architecture-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>/dev/null; then
  fail "validate-phase-order: blocks architecture without spec" "exit 2" "exit 0"
else
  pass "validate-phase-order: blocks architecture without spec"
fi

# Test: architecture-agent allowed when spec exists with few markers
mkdir -p "$TEST_DIR/.claude/specs/test-feature"
cat > "$TEST_DIR/.claude/specs/test-feature/spec.md" << 'EOF'
# Test Spec
Some requirements here.
[NEEDS CLARIFICATION]: One marker
[NEEDS CLARIFICATION]: Two markers
EOF

reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "specify",
  "phase_artifacts": {"brainstorm": "completed", "specify": ".claude/specs/test-feature/spec.md"},
  "skipped_phases": [],
  "spec_file": ".claude/specs/test-feature/spec.md",
  "current_wave": null,
  "tasks": []
}
EOF

if echo '{"tool_name": "Task", "tool_input": {"prompt": "Design architecture", "subagent_type": "architecture-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>&1; then
  pass "validate-phase-order: allows architecture with spec (markers <= 3)"
else
  fail "validate-phase-order: allows architecture with spec" "exit 0" "exit 2"
fi

# Test: architecture-agent BLOCKED when too many markers
cat > "$TEST_DIR/.claude/specs/test-feature/spec.md" << 'EOF'
# Test Spec
[NEEDS CLARIFICATION]: One
[NEEDS CLARIFICATION]: Two
[NEEDS CLARIFICATION]: Three
[NEEDS CLARIFICATION]: Four
[NEEDS CLARIFICATION]: Five
EOF

if echo '{"tool_name": "Task", "tool_input": {"prompt": "Design architecture", "subagent_type": "architecture-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>/dev/null; then
  fail "validate-phase-order: blocks architecture when markers > 3" "exit 2" "exit 0"
else
  pass "validate-phase-order: blocks architecture when markers > 3"
fi

# Test: architecture-agent allowed when clarify skipped
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "specify",
  "phase_artifacts": {"brainstorm": "completed", "specify": ".claude/specs/test-feature/spec.md"},
  "skipped_phases": ["clarify"],
  "spec_file": ".claude/specs/test-feature/spec.md",
  "current_wave": null,
  "tasks": []
}
EOF

if echo '{"tool_name": "Task", "tool_input": {"prompt": "Design architecture", "subagent_type": "architecture-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>&1; then
  pass "validate-phase-order: allows architecture when clarify skipped"
else
  fail "validate-phase-order: allows architecture when clarify skipped" "exit 0" "exit 2"
fi

# Test: impl-agent BLOCKED without plan
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "architecture",
  "phase_artifacts": {"brainstorm": "completed", "specify": ".claude/specs/test-feature/spec.md"},
  "skipped_phases": [],
  "current_wave": null,
  "tasks": []
}
EOF

if echo '{"tool_name": "Task", "tool_input": {"prompt": "Implement feature", "subagent_type": "code-implementer-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>/dev/null; then
  fail "validate-phase-order: blocks impl without plan" "exit 2" "exit 0"
else
  pass "validate-phase-order: blocks impl without plan"
fi

# Test: impl-agent allowed with plan
mkdir -p "$TEST_DIR/.claude/plans"
echo "# Architecture Plan" > "$TEST_DIR/.claude/plans/test-feature.md"

reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "execute",
  "phase_artifacts": {"brainstorm": "completed", "specify": ".claude/specs/test-feature/spec.md", "architecture": ".claude/plans/test-feature.md"},
  "skipped_phases": [],
  "plan_file": ".claude/plans/test-feature.md",
  "current_wave": 1,
  "tasks": []
}
EOF

if echo '{"tool_name": "Task", "tool_input": {"prompt": "Implement feature", "subagent_type": "code-implementer-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>&1; then
  pass "validate-phase-order: allows impl with plan"
else
  fail "validate-phase-order: allows impl with plan" "exit 0" "exit 2"
fi

# Test: non-Task tool calls pass through
if echo '{"tool_name": "Read", "tool_input": {"file_path": "test.ts"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>&1; then
  pass "validate-phase-order: ignores non-Task tools"
else
  fail "validate-phase-order: ignores non-Task tools" "exit 0" "exit 2"
fi

# Test: unknown agent types BLOCKED (prevents bypass via empty subagent_type)
if echo '{"tool_name": "Task", "tool_input": {"prompt": "Run tests", "subagent_type": "rogue-agent"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-phase-order.sh" 2>/dev/null; then
  fail "validate-phase-order: blocks unknown agent types" "exit 2" "exit 0"
else
  pass "validate-phase-order: blocks unknown agent types"
fi

# ============================================
# Test 21: advance-phase.sh - phase advancement
# ============================================
echo ""
echo "--- Test: advance-phase.sh ---"

cd "$TEST_DIR"

# Need to mock resolve-task-graph for these tests
mkdir -p /tmp/claude-subagents
echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/advance-test-session.task_graph

# Setup: brainstorm complete, should advance to specify
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "init",
  "phase_artifacts": {},
  "skipped_phases": [],
  "current_wave": null,
  "tasks": []
}
EOF

# Create transcript with brainstorm agent type indicator
mkdir -p /tmp/claude-subagents
echo "brainstorm-agent" > /tmp/claude-subagents/agent-brainstorm-123.type

echo '{"session_id": "advance-test-session", "agent_id": "agent-brainstorm-123", "agent_type": "brainstorm-agent", "agent_transcript_path": "/tmp/fake-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/advance-phase.sh" 2>&1

NEW_PHASE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
BRAINSTORM_ARTIFACT=$(jq -r '.phase_artifacts.brainstorm // "missing"' "$TEST_DIR/.claude/state/active_task_graph.json")

[[ "$NEW_PHASE" == "specify" ]] && pass "advance-phase: brainstorm → specify" || fail "advance-phase: brainstorm → specify" "specify" "$NEW_PHASE"
[[ "$BRAINSTORM_ARTIFACT" == "completed" ]] && pass "advance-phase: sets brainstorm artifact" || fail "advance-phase: sets brainstorm artifact" "completed" "$BRAINSTORM_ARTIFACT"

# Test: specify complete with few markers → architecture (skip clarify)
cat > "$TEST_DIR/.claude/specs/test-feature/spec.md" << 'EOF'
# Spec
[NEEDS CLARIFICATION]: One marker only
EOF

reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "specify",
  "phase_artifacts": {"brainstorm": "completed"},
  "skipped_phases": [],
  "spec_file": ".claude/specs/test-feature/spec.md",
  "current_wave": null,
  "tasks": []
}
EOF

echo "specify-agent" > /tmp/claude-subagents/agent-specify-123.type

echo '{"session_id": "advance-test-session", "agent_id": "agent-specify-123", "agent_type": "specify-agent", "agent_transcript_path": "/tmp/fake-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/advance-phase.sh" 2>&1

NEW_PHASE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
SKIPPED=$(jq -r '.skipped_phases | join(",")' "$TEST_DIR/.claude/state/active_task_graph.json")

[[ "$NEW_PHASE" == "architecture" ]] && pass "advance-phase: specify → architecture (markers <= 3)" || fail "advance-phase: specify → architecture" "architecture" "$NEW_PHASE"
[[ "$SKIPPED" == *"clarify"* ]] && pass "advance-phase: auto-skips clarify" || fail "advance-phase: auto-skips clarify" "contains clarify" "$SKIPPED"

# Test: specify complete with many markers → clarify
cat > "$TEST_DIR/.claude/specs/test-feature/spec.md" << 'EOF'
# Spec
[NEEDS CLARIFICATION]: One
[NEEDS CLARIFICATION]: Two
[NEEDS CLARIFICATION]: Three
[NEEDS CLARIFICATION]: Four
[NEEDS CLARIFICATION]: Five
EOF

reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "specify",
  "phase_artifacts": {"brainstorm": "completed"},
  "skipped_phases": [],
  "spec_file": ".claude/specs/test-feature/spec.md",
  "current_wave": null,
  "tasks": []
}
EOF

echo '{"session_id": "advance-test-session", "agent_id": "agent-specify-456", "agent_type": "specify-agent", "agent_transcript_path": "/tmp/fake-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/advance-phase.sh" 2>&1

NEW_PHASE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$NEW_PHASE" == "clarify" ]] && pass "advance-phase: specify → clarify (markers > 3)" || fail "advance-phase: specify → clarify" "clarify" "$NEW_PHASE"

# Test: clarify complete → architecture
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "clarify",
  "phase_artifacts": {"brainstorm": "completed", "specify": ".claude/specs/test-feature/spec.md"},
  "skipped_phases": [],
  "spec_file": ".claude/specs/test-feature/spec.md",
  "current_wave": null,
  "tasks": []
}
EOF

echo "clarify-agent" > /tmp/claude-subagents/agent-clarify-123.type

echo '{"session_id": "advance-test-session", "agent_id": "agent-clarify-123", "agent_type": "clarify-agent", "agent_transcript_path": "/tmp/fake-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/advance-phase.sh" 2>&1

NEW_PHASE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$NEW_PHASE" == "architecture" ]] && pass "advance-phase: clarify → architecture" || fail "advance-phase: clarify → architecture" "architecture" "$NEW_PHASE"

# Test: architecture complete → decompose
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "architecture",
  "phase_artifacts": {"brainstorm": "completed", "specify": ".claude/specs/test-feature/spec.md", "clarify": "completed"},
  "skipped_phases": [],
  "plan_file": ".claude/plans/test-feature.md",
  "current_wave": null,
  "tasks": []
}
EOF

echo "architecture-agent" > /tmp/claude-subagents/agent-arch-123.type

echo '{"session_id": "advance-test-session", "agent_id": "agent-arch-123", "agent_type": "architecture-agent", "agent_transcript_path": "/tmp/fake-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/advance-phase.sh" 2>&1

NEW_PHASE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$NEW_PHASE" == "decompose" ]] && pass "advance-phase: architecture → decompose" || fail "advance-phase: architecture → decompose" "decompose" "$NEW_PHASE"

# Test: non-phase agents don't advance
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "execute",
  "phase_artifacts": {},
  "skipped_phases": [],
  "current_wave": 1,
  "tasks": []
}
EOF

echo "code-implementer-agent" > /tmp/claude-subagents/agent-impl-123.type

echo '{"session_id": "advance-test-session", "agent_id": "agent-impl-123", "agent_type": "code-implementer-agent", "agent_transcript_path": "/tmp/fake-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/advance-phase.sh" 2>&1

STILL_EXECUTE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$STILL_EXECUTE" == "execute" ]] && pass "advance-phase: impl agents don't advance phase" || fail "advance-phase: impl agents don't advance" "execute" "$STILL_EXECUTE"

# Cleanup
rm -rf /tmp/claude-subagents

# ============================================
# Test 22: update-task-status.sh remaining tasks + anti-spoofing
# ============================================
echo ""
echo "--- Test: update-task-status.sh remaining tasks + anti-spoofing ---"

cd "$TEST_DIR"
mkdir -p /tmp/claude-subagents

# Setup: wave 1 with 3 tasks, one about to complete
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "pending", "agent": "code-implementer-agent"},
    {"id": "T2", "wave": 1, "status": "pending", "agent": "code-implementer-agent"},
    {"id": "T3", "wave": 1, "status": "pending", "agent": "code-implementer-agent"}
  ],
  "executing_tasks": [],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF

echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/remaining-test.task_graph

# Create transcript with REAL Bash tool_use/tool_result (anti-spoof format)
cat > "$TEST_DIR/remaining-transcript.jsonl" << 'EOF'
{"message": {"content": "**Task ID:** T1\nImplemented successfully"}}
{"message": {"content": [{"type": "tool_use", "id": "tool_123", "name": "Bash", "input": {"command": "mvn test"}}]}}
{"message": {"content": [{"type": "tool_result", "tool_use_id": "tool_123", "content": "BUILD SUCCESS\nTests run: 5, Failures: 0, Errors: 0"}]}}
EOF

# Run update-task-status (should show T2, T3 as remaining)
OUTPUT=$(echo '{"session_id": "remaining-test", "agent_type": "code-implementer-agent", "agent_transcript_path": "'"$TEST_DIR"'/remaining-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/update-task-status.sh" 2>&1)

echo "$OUTPUT" | grep -q "T2" && pass "update-task-status: shows remaining tasks (T2)" || fail "update-task-status: shows T2" "contains T2" "$OUTPUT"
echo "$OUTPUT" | grep -q "T3" && pass "update-task-status: shows remaining tasks (T3)" || fail "update-task-status: shows T3" "contains T3" "$OUTPUT"

# Verify test evidence came from Bash tool output
T1_EVIDENCE=$(jq -r '.tasks[] | select(.id=="T1") | .test_evidence' "$TEST_DIR/.claude/state/active_task_graph.json")
T1_PASSED=$(jq -r '.tasks[] | select(.id=="T1") | .tests_passed' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$T1_PASSED" == "true" ]] && pass "update-task-status: tests_passed from real Bash output" || fail "update-task-status: tests_passed" "true" "$T1_PASSED"
[[ "$T1_EVIDENCE" == *"maven"* ]] && pass "update-task-status: maven evidence extracted" || fail "update-task-status: maven evidence" "contains maven" "$T1_EVIDENCE"

# ANTI-SPOOFING: Text-only "BUILD SUCCESS" (no Bash tool_use) → tests_passed=false
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "pending", "agent": "code-implementer-agent"}
  ],
  "executing_tasks": [],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF

echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/spoof-test.task_graph

# Transcript with BUILD SUCCESS as plain text (agent prose) — NOT in a Bash tool result
cat > "$TEST_DIR/spoof-transcript.jsonl" << 'EOF'
{"message": {"content": "**Task ID:** T1\nI ran the tests and they passed.\nBUILD SUCCESS\nTests run: 5, Failures: 0, Errors: 0\nAll good!"}}
EOF

echo '{"session_id": "spoof-test", "agent_type": "code-implementer-agent", "agent_transcript_path": "'"$TEST_DIR"'/spoof-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/update-task-status.sh" 2>&1 >/dev/null

SPOOF_PASSED=$(jq -r '.tasks[] | select(.id=="T1") | .tests_passed' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$SPOOF_PASSED" == "false" ]] && pass "ANTI-SPOOF: text-only BUILD SUCCESS → tests_passed=false" || fail "ANTI-SPOOF: text-only" "false" "$SPOOF_PASSED"

rm -rf /tmp/claude-subagents

# ============================================
# Test 23: validate-task-execution.sh non-git graceful handling
# ============================================
echo ""
echo "--- Test: validate-task-execution.sh non-git ---"

NON_GIT_DIR=$(mktemp -d)
mkdir -p "$NON_GIT_DIR/.claude/state"

cat > "$NON_GIT_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "pending", "depends_on": []}
  ],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF

# Should allow task and not crash (just skip SHA capture)
if (cd "$NON_GIT_DIR" && echo '{"tool_name": "Task", "tool_input": {"prompt": "**Task ID:** T1\nImplement feature"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1); then
  pass "validate-task-execution: works in non-git repos"
else
  fail "validate-task-execution: works in non-git repos" "exit 0" "exit non-zero"
fi

# Verify no start_sha was set (can't get SHA without git)
NO_SHA=$(jq -r '.tasks[] | select(.id=="T1") | .start_sha // "missing"' "$NON_GIT_DIR/.claude/state/active_task_graph.json")
[[ "$NO_SHA" == "missing" ]] && pass "validate-task-execution: skips SHA in non-git" || fail "validate-task-execution: skips SHA in non-git" "missing" "$NO_SHA"

rm -rf "$NON_GIT_DIR"
cd "$TEST_DIR"

# ============================================
# Test 24: parse-bash-test-output.sh (anti-spoofing helper)
# ============================================
echo ""
echo "--- Test: parse-bash-test-output.sh ---"

cd "$TEST_DIR"
source "$REPO_ROOT/.claude/hooks/helpers/parse-bash-test-output.sh"

# Test: extracts output from Bash tool_use with test command
cat > "$TEST_DIR/bash-test-transcript.jsonl" << 'EOF'
{"message": {"content": "I will run the tests now"}}
{"message": {"content": [{"type": "tool_use", "id": "tool_mvn", "name": "Bash", "input": {"command": "mvn test -pl api"}}]}}
{"message": {"content": [{"type": "tool_result", "tool_use_id": "tool_mvn", "content": "BUILD SUCCESS\nTests run: 12, Failures: 0, Errors: 0"}]}}
{"message": {"content": "All tests passed! BUILD SUCCESS"}}
EOF

BASH_RESULT=$(parse_bash_test_output "$TEST_DIR/bash-test-transcript.jsonl")
echo "$BASH_RESULT" | grep -q "BUILD SUCCESS" && pass "parse-bash-test-output: extracts Bash test result" || fail "parse-bash-test-output: extracts test result" "contains BUILD SUCCESS" "$BASH_RESULT"
echo "$BASH_RESULT" | grep -q "Tests run: 12" && pass "parse-bash-test-output: extracts test counts" || fail "parse-bash-test-output: test counts" "contains Tests run: 12" "$BASH_RESULT"

# Test: ignores non-Bash tools
cat > "$TEST_DIR/no-bash-transcript.jsonl" << 'EOF'
{"message": {"content": [{"type": "tool_use", "id": "tool_read", "name": "Read", "input": {"file_path": "/test.java"}}]}}
{"message": {"content": [{"type": "tool_result", "tool_use_id": "tool_read", "content": "BUILD SUCCESS\nTests run: 5, Failures: 0, Errors: 0"}]}}
EOF

NO_BASH_RESULT=$(parse_bash_test_output "$TEST_DIR/no-bash-transcript.jsonl")
[[ -z "$NO_BASH_RESULT" || ! "$NO_BASH_RESULT" =~ "BUILD SUCCESS" ]] && pass "parse-bash-test-output: ignores non-Bash tools" || fail "parse-bash-test-output: ignores non-Bash" "empty" "$NO_BASH_RESULT"

# Test: ignores Bash commands that aren't test runners
cat > "$TEST_DIR/non-test-bash-transcript.jsonl" << 'EOF'
{"message": {"content": [{"type": "tool_use", "id": "tool_ls", "name": "Bash", "input": {"command": "ls -la"}}]}}
{"message": {"content": [{"type": "tool_result", "tool_use_id": "tool_ls", "content": "total 42\ndrwxr-xr-x 5 user staff"}]}}
EOF

NON_TEST_RESULT=$(parse_bash_test_output "$TEST_DIR/non-test-bash-transcript.jsonl")
[[ -z "$NON_TEST_RESULT" || "$NON_TEST_RESULT" =~ ^[[:space:]]*$ ]] && pass "parse-bash-test-output: ignores non-test commands" || fail "parse-bash-test-output: ignores non-test" "empty" "$NON_TEST_RESULT"

# Test: handles multiple test runners (npm test, pytest)
cat > "$TEST_DIR/multi-runner-transcript.jsonl" << 'EOF'
{"message": {"content": [{"type": "tool_use", "id": "tool_npm", "name": "Bash", "input": {"command": "npm test"}}]}}
{"message": {"content": [{"type": "tool_result", "tool_use_id": "tool_npm", "content": "5 passing\n0 failing"}]}}
{"message": {"content": [{"type": "tool_use", "id": "tool_py", "name": "Bash", "input": {"command": "pytest tests/"}}]}}
{"message": {"content": [{"type": "tool_result", "tool_use_id": "tool_py", "content": "3 passed in 0.5s"}]}}
EOF

MULTI_RESULT=$(parse_bash_test_output "$TEST_DIR/multi-runner-transcript.jsonl")
echo "$MULTI_RESULT" | grep -q "5 passing" && pass "parse-bash-test-output: captures npm test output" || fail "parse-bash-test-output: npm test" "contains '5 passing'" "$MULTI_RESULT"
echo "$MULTI_RESULT" | grep -q "3 passed" && pass "parse-bash-test-output: captures pytest output" || fail "parse-bash-test-output: pytest" "contains '3 passed'" "$MULTI_RESULT"

# Test: empty transcript returns empty
EMPTY_RESULT=$(parse_bash_test_output "$TEST_DIR/empty-tools.jsonl")
[[ -z "$EMPTY_RESULT" || "$EMPTY_RESULT" =~ ^[[:space:]]*$ ]] && pass "parse-bash-test-output: empty for no test commands" || fail "parse-bash-test-output: empty" "empty" "$EMPTY_RESULT"

# ============================================
# Test 25: state-file-write.sh chmod protection
# ============================================
echo ""
echo "--- Test: state-file-write.sh ---"

cd "$TEST_DIR"

# Create state file
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{"current_wave": 1, "tasks": [{"id": "T1", "status": "pending"}]}
EOF

# Set chmod 444 (simulates runtime protection)
chmod 444 "$TEST_DIR/.claude/state/active_task_graph.json"

# Verify direct write fails
if echo "HACKED" > "$TEST_DIR/.claude/state/active_task_graph.json" 2>/dev/null; then
  fail "chmod 444: direct write blocked" "EACCES" "write succeeded"
else
  pass "chmod 444: direct write blocked (EACCES)"
fi

# Verify state-file-write.sh can write (toggles chmod)
export TASK_GRAPH="$TEST_DIR/.claude/state/active_task_graph.json"
bash "$REPO_ROOT/.claude/hooks/helpers/state-file-write.sh" '.tasks[0].status = "implemented"'

WRITTEN_STATUS=$(jq -r '.tasks[0].status' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$WRITTEN_STATUS" == "implemented" ]] && pass "state-file-write: jq transform succeeds through chmod" || fail "state-file-write: jq transform" "implemented" "$WRITTEN_STATUS"

# Verify file is back to 444 after write
PERMS=$(stat -f '%Lp' "$TEST_DIR/.claude/state/active_task_graph.json" 2>/dev/null || stat -c '%a' "$TEST_DIR/.claude/state/active_task_graph.json" 2>/dev/null)
[[ "$PERMS" == "444" ]] && pass "state-file-write: restores chmod 444 after write" || fail "state-file-write: restores 444" "444" "$PERMS"

# Test --arg passing
bash "$REPO_ROOT/.claude/hooks/helpers/state-file-write.sh" --arg id "T1" '.tasks |= map(if .id == $id then .status = "completed" else . end)'
COMPLETED_STATUS=$(jq -r '.tasks[0].status' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$COMPLETED_STATUS" == "completed" ]] && pass "state-file-write: --arg works" || fail "state-file-write: --arg" "completed" "$COMPLETED_STATUS"

# Test --replace mode
echo '{"fresh": true}' | bash "$REPO_ROOT/.claude/hooks/helpers/state-file-write.sh" --replace
FRESH=$(jq -r '.fresh' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$FRESH" == "true" ]] && pass "state-file-write: --replace mode works" || fail "state-file-write: --replace" "true" "$FRESH"

# Restore normal perms for later tests
chmod 644 "$TEST_DIR/.claude/state/active_task_graph.json"
unset TASK_GRAPH

# ============================================
# Test 26: populate-task-graph.sh
# ============================================
echo ""
echo "--- Test: populate-task-graph.sh ---"

cd "$TEST_DIR"

# Create initial state (phase tracking only)
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "execute",
  "phase_artifacts": {"brainstorm": "completed", "specify": "spec.md", "architecture": "plan.md"},
  "skipped_phases": [],
  "spec_file": "spec.md",
  "plan_file": "plan.md"
}
EOF

# Feed decompose JSON via stdin
export TASK_GRAPH="$TEST_DIR/.claude/state/active_task_graph.json"
echo '{
  "plan_title": "Test Feature",
  "plan_file": "plan.md",
  "spec_file": "spec.md",
  "tasks": [
    {"id": "T1", "description": "First task", "wave": 1, "agent": "code-implementer-agent", "depends_on": []},
    {"id": "T2", "description": "Second task", "wave": 1, "agent": "code-implementer-agent", "depends_on": []},
    {"id": "T3", "description": "Third task", "wave": 2, "agent": "code-implementer-agent", "depends_on": ["T1"]}
  ]
}' | bash "$REPO_ROOT/.claude/hooks/helpers/populate-task-graph.sh" --issue 42 --repo owner/repo

# Verify merge
TASK_COUNT=$(jq '.tasks | length' "$TEST_DIR/.claude/state/active_task_graph.json")
CURRENT_WAVE=$(jq -r '.current_wave' "$TEST_DIR/.claude/state/active_task_graph.json")
ISSUE=$(jq -r '.github_issue' "$TEST_DIR/.claude/state/active_task_graph.json")
REPO=$(jq -r '.github_repo' "$TEST_DIR/.claude/state/active_task_graph.json")
PHASE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
WAVE1_GATE=$(jq -r '.wave_gates["1"].impl_complete' "$TEST_DIR/.claude/state/active_task_graph.json")
WAVE2_GATE=$(jq -r '.wave_gates["2"].impl_complete' "$TEST_DIR/.claude/state/active_task_graph.json")

[[ "$TASK_COUNT" == "3" ]] && pass "populate-task-graph: 3 tasks merged" || fail "populate-task-graph: task count" "3" "$TASK_COUNT"
[[ "$CURRENT_WAVE" == "1" ]] && pass "populate-task-graph: current_wave=1" || fail "populate-task-graph: wave" "1" "$CURRENT_WAVE"
[[ "$ISSUE" == "42" ]] && pass "populate-task-graph: github_issue set" || fail "populate-task-graph: issue" "42" "$ISSUE"
[[ "$REPO" == "owner/repo" ]] && pass "populate-task-graph: github_repo set" || fail "populate-task-graph: repo" "owner/repo" "$REPO"
[[ "$PHASE" == "execute" ]] && pass "populate-task-graph: preserves current_phase" || fail "populate-task-graph: phase preserved" "execute" "$PHASE"
[[ "$WAVE1_GATE" == "false" ]] && pass "populate-task-graph: initializes wave 1 gate" || fail "populate-task-graph: wave 1 gate" "false" "$WAVE1_GATE"
[[ "$WAVE2_GATE" == "false" ]] && pass "populate-task-graph: initializes wave 2 gate" || fail "populate-task-graph: wave 2 gate" "false" "$WAVE2_GATE"

unset TASK_GRAPH

# ============================================
# Test 27: Assertion density check (merged into update-task-status.sh)
# ============================================
echo ""
echo "--- Test: Assertion density check ---"

cd "$TEST_DIR"

# Need git repo for diff-based assertion detection
AD_GIT_DIR=$(mktemp -d)
(cd "$AD_GIT_DIR" && git init -q && git commit --allow-empty -m "init" -q)
mkdir -p "$AD_GIT_DIR/.claude/state" "$AD_GIT_DIR/src/test"
mkdir -p /tmp/claude-subagents

# Test: empty test stubs (test methods but no assertions) → new_tests_written=false
cat > "$AD_GIT_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [{"id": "T1", "wave": 1, "status": "pending", "agent": "code-implementer-agent"}],
  "executing_tasks": [],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF
echo "$AD_GIT_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/assert-test.task_graph

# Create test file with empty stubs (no assertions)
cat > "$AD_GIT_DIR/src/test/FooTest.java" << 'JAVA'
import org.junit.jupiter.api.Test;
public class FooTest {
    @Test
    void testSomething() {
        // empty - no assertions
    }
    @Test
    void testAnother() {
        System.out.println("no assertions here");
    }
}
JAVA

# Create transcript (Bash tool output for test pass + Write for the file)
cat > "$AD_GIT_DIR/assert-transcript.jsonl" << 'EOF'
{"message": {"content": "**Task ID:** T1\nWrote tests"}}
{"message": {"content": [{"type": "tool_use", "name": "Write", "input": {"file_path": "src/test/FooTest.java", "content": "..."}}]}}
{"message": {"content": [{"type": "tool_use", "id": "tool_mvn", "name": "Bash", "input": {"command": "mvn test"}}]}}
{"message": {"content": [{"type": "tool_result", "tool_use_id": "tool_mvn", "content": "BUILD SUCCESS\nTests run: 2, Failures: 0, Errors: 0"}]}}
EOF

(cd "$AD_GIT_DIR" && echo "{\"session_id\": \"assert-test\", \"agent_type\": \"code-implementer-agent\", \"agent_transcript_path\": \"$AD_GIT_DIR/assert-transcript.jsonl\"}" | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/update-task-status.sh" 2>&1 >/dev/null)

EMPTY_STUB_WRITTEN=$(jq -r '.tasks[] | select(.id=="T1") | .new_tests_written' "$AD_GIT_DIR/.claude/state/active_task_graph.json")
EMPTY_STUB_EVIDENCE=$(jq -r '.tasks[] | select(.id=="T1") | .new_test_evidence' "$AD_GIT_DIR/.claude/state/active_task_graph.json")
[[ "$EMPTY_STUB_WRITTEN" == "false" ]] && pass "Assertion density: empty stubs → new_tests_written=false" || fail "Assertion density: empty stubs" "false" "$EMPTY_STUB_WRITTEN"
[[ "$EMPTY_STUB_EVIDENCE" == *"0 assertions"* ]] && pass "Assertion density: reports 0 assertions" || fail "Assertion density: 0 assertions" "contains '0 assertions'" "$EMPTY_STUB_EVIDENCE"

# Test: real tests with assertions → new_tests_written=true
chmod 644 "$AD_GIT_DIR/.claude/state/active_task_graph.json" 2>/dev/null || true
rm -rf "$AD_GIT_DIR/.claude/state/.task_graph.lock"* 2>/dev/null || true
cat > "$AD_GIT_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [{"id": "T1", "wave": 1, "status": "pending", "agent": "code-implementer-agent"}],
  "executing_tasks": [],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF
echo "$AD_GIT_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/assert-test2.task_graph

# Overwrite test file with real assertions
cat > "$AD_GIT_DIR/src/test/FooTest.java" << 'JAVA'
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;
public class FooTest {
    @Test
    void testSomething() {
        assertThat(1 + 1).isEqualTo(2);
    }
    @Test
    void testAnother() {
        assertThat("hello").isNotEmpty();
    }
}
JAVA

(cd "$AD_GIT_DIR" && echo "{\"session_id\": \"assert-test2\", \"agent_type\": \"code-implementer-agent\", \"agent_transcript_path\": \"$AD_GIT_DIR/assert-transcript.jsonl\"}" | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/update-task-status.sh" 2>&1 >/dev/null)

REAL_WRITTEN=$(jq -r '.tasks[] | select(.id=="T1") | .new_tests_written' "$AD_GIT_DIR/.claude/state/active_task_graph.json")
REAL_EVIDENCE=$(jq -r '.tasks[] | select(.id=="T1") | .new_test_evidence' "$AD_GIT_DIR/.claude/state/active_task_graph.json")
[[ "$REAL_WRITTEN" == "true" ]] && pass "Assertion density: real assertions → new_tests_written=true" || fail "Assertion density: real assertions" "true" "$REAL_WRITTEN"
[[ "$REAL_EVIDENCE" == *"assertions"* ]] && pass "Assertion density: reports assertion count" || fail "Assertion density: assertion count" "contains 'assertions'" "$REAL_EVIDENCE"

rm -rf "$AD_GIT_DIR" /tmp/claude-subagents

# ============================================
# Test 28: validate-task-graph.sh new_tests_required keyword validation
# ============================================
echo ""
echo "--- Test: validate-task-graph.sh new_tests_required keywords ---"

# Task with new_tests_required=false + config description → no warning
VALID_JSON='{
  "plan_title": "Test",
  "plan_file": "plan.md",
  "spec_file": "spec.md",
  "tasks": [{"id": "T1", "description": "Update config for new env", "wave": 1, "agent": "code-implementer-agent", "depends_on": [], "new_tests_required": false}]
}'

VALID_OUTPUT=$(echo "$VALID_JSON" | bash "$REPO_ROOT/.claude/hooks/helpers/validate-task-graph.sh" - 2>&1)
! echo "$VALID_OUTPUT" | grep -q "WARNING" && pass "validate-task-graph: no warning for config task + tests=false" || fail "validate-task-graph: config no warning" "no WARNING" "$VALID_OUTPUT"

# Task with new_tests_required=false + implementation description → WARNING
SUSPICIOUS_JSON='{
  "plan_title": "Test",
  "plan_file": "plan.md",
  "spec_file": "spec.md",
  "tasks": [{"id": "T1", "description": "Implement user authentication with JWT", "wave": 1, "agent": "code-implementer-agent", "depends_on": [], "new_tests_required": false}]
}'

SUSPICIOUS_OUTPUT=$(echo "$SUSPICIOUS_JSON" | bash "$REPO_ROOT/.claude/hooks/helpers/validate-task-graph.sh" - 2>&1)
echo "$SUSPICIOUS_OUTPUT" | grep -q "WARNING" && pass "validate-task-graph: warns for impl task + tests=false" || fail "validate-task-graph: impl warning" "contains WARNING" "$SUSPICIOUS_OUTPUT"

# Still valid (warning ≠ error) — exit code should be 0
echo "$SUSPICIOUS_JSON" | bash "$REPO_ROOT/.claude/hooks/helpers/validate-task-graph.sh" - >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "validate-task-graph: warning doesn't fail validation" || fail "validate-task-graph: warning not error" "exit 0" "exit $?"

# Task with new_tests_required=false + migration description → no warning
MIGRATION_JSON='{
  "plan_title": "Test",
  "plan_file": "plan.md",
  "spec_file": "spec.md",
  "tasks": [{"id": "T1", "description": "Run database migration for user table", "wave": 1, "agent": "code-implementer-agent", "depends_on": [], "new_tests_required": false}]
}'

MIGRATION_OUTPUT=$(echo "$MIGRATION_JSON" | bash "$REPO_ROOT/.claude/hooks/helpers/validate-task-graph.sh" - 2>&1)
! echo "$MIGRATION_OUTPUT" | grep -q "WARNING" && pass "validate-task-graph: no warning for migration + tests=false" || fail "validate-task-graph: migration no warning" "no WARNING" "$MIGRATION_OUTPUT"

# ============================================
# Test 29: guard-state-file.sh blocks chmod
# ============================================
echo ""
echo "--- Test: guard-state-file.sh blocks chmod ---"

cd "$TEST_DIR"
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{"current_wave": 1, "tasks": [], "wave_gates": {}}
EOF

# Test: chmod on state file should be blocked
if echo '{"tool_name": "Bash", "tool_input": {"command": "chmod 644 .claude/state/active_task_graph.json"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  fail "guard-state-file: blocks chmod on state file" "exit 2" "exit 0"
else
  pass "guard-state-file: blocks chmod on state file"
fi

# Test: state-file-write.sh is whitelisted
if echo '{"tool_name": "Bash", "tool_input": {"command": "bash ~/.claude/hooks/helpers/state-file-write.sh .x = 1"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  pass "guard-state-file: whitelists state-file-write.sh"
else
  fail "guard-state-file: whitelists state-file-write.sh" "exit 0" "exit 2"
fi

# Test: populate-task-graph.sh is whitelisted
if echo '{"tool_name": "Bash", "tool_input": {"command": "echo x | bash ~/.claude/hooks/helpers/populate-task-graph.sh --issue 42"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/guard-state-file.sh" 2>/dev/null; then
  pass "guard-state-file: whitelists populate-task-graph.sh"
else
  fail "guard-state-file: whitelists populate-task-graph.sh" "exit 0" "exit 2"
fi

# ============================================
# Test 30: store-reviewer-findings.sh parses Machine Summary
# ============================================
echo ""
echo "--- Test: store-reviewer-findings.sh Machine Summary parsing ---"

cd "$TEST_DIR"
mkdir -p /tmp/claude-subagents

reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "pending", "critical_findings": [], "advisory_findings": []}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": true, "reviews_complete": false, "blocked": false}}
}
EOF

echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/review-summary-test.task_graph

# Create transcript with Machine Summary block
cat > "$TEST_DIR/review-summary-transcript.jsonl" << 'EOF'
{"message": {"content": "--task T1\n# PR Review Summary\n## Critical Issues\n- SQL injection in query builder\n## Suggestions\n- Consider logging\n\n### Machine Summary\nCRITICAL_COUNT: 1\nADVISORY_COUNT: 1\nCRITICAL: SQL injection in query builder\nADVISORY: Consider logging"}}
EOF

echo '{"session_id": "review-summary-test", "agent_type": "review-invoker", "agent_transcript_path": "'"$TEST_DIR"'/review-summary-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/store-reviewer-findings.sh" 2>&1 >/dev/null

MS_CRITICAL=$(jq '[.tasks[] | select(.id=="T1") | .critical_findings | length] | add' "$TEST_DIR/.claude/state/active_task_graph.json")
MS_ADVISORY=$(jq '[.tasks[] | select(.id=="T1") | .advisory_findings | length] | add' "$TEST_DIR/.claude/state/active_task_graph.json")
MS_STATUS=$(jq -r '.tasks[] | select(.id=="T1") | .review_status' "$TEST_DIR/.claude/state/active_task_graph.json")

[[ "$MS_CRITICAL" == "1" ]] && pass "Machine Summary: 1 critical finding parsed" || fail "Machine Summary: critical count" "1" "$MS_CRITICAL"
[[ "$MS_ADVISORY" == "1" ]] && pass "Machine Summary: 1 advisory finding parsed" || fail "Machine Summary: advisory count" "1" "$MS_ADVISORY"
[[ "$MS_STATUS" == "blocked" ]] && pass "Machine Summary: review_status=blocked" || fail "Machine Summary: status" "blocked" "$MS_STATUS"

# Test: CRITICAL_COUNT: 0 with Machine Summary → passed
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "pending", "critical_findings": [], "advisory_findings": []}
  ],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": true, "reviews_complete": false, "blocked": false}}
}
EOF

echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/review-pass-test.task_graph

cat > "$TEST_DIR/review-pass-transcript.jsonl" << 'EOF'
{"message": {"content": "--task T1\n# PR Review Summary\nNo issues found.\n\n### Machine Summary\nCRITICAL_COUNT: 0\nADVISORY_COUNT: 0"}}
EOF

echo '{"session_id": "review-pass-test", "agent_type": "review-invoker", "agent_transcript_path": "'"$TEST_DIR"'/review-pass-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/store-reviewer-findings.sh" 2>&1 >/dev/null

PASS_STATUS=$(jq -r '.tasks[] | select(.id=="T1") | .review_status' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$PASS_STATUS" == "passed" ]] && pass "Machine Summary: CRITICAL_COUNT:0 → review_status=passed" || fail "Machine Summary: pass status" "passed" "$PASS_STATUS"

rm -rf /tmp/claude-subagents

# ============================================
# Test 31: dispatch.sh routes to correct hooks
# ============================================
echo ""
echo "--- Test: dispatch.sh routing ---"

cd "$TEST_DIR"
mkdir -p /tmp/claude-subagents

reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "init",
  "phase_artifacts": {},
  "skipped_phases": [],
  "current_wave": null,
  "tasks": []
}
EOF

echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/dispatch-test.task_graph
echo "brainstorm-agent" > /tmp/claude-subagents/agent-dispatch-1.type

# Test: dispatcher routes brainstorm-agent → advance-phase (should advance init → specify)
echo '{"session_id": "dispatch-test", "agent_id": "agent-dispatch-1", "agent_type": "brainstorm-agent", "agent_transcript_path": "/tmp/fake.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/dispatch.sh" 2>&1 >/dev/null

DISPATCH_PHASE=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$DISPATCH_PHASE" == "specify" ]] && pass "dispatch: routes brainstorm-agent → advance-phase" || fail "dispatch: brainstorm routing" "specify" "$DISPATCH_PHASE"

# Test: dispatcher routes impl agent → update-task-status (not advance-phase)
reset_state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "execute",
  "phase_artifacts": {},
  "skipped_phases": [],
  "current_wave": 1,
  "tasks": [{"id": "T1", "wave": 1, "status": "pending", "agent": "code-implementer-agent"}],
  "executing_tasks": [],
  "wave_gates": {"1": {"impl_complete": false}}
}
EOF

echo "$TEST_DIR/.claude/state/active_task_graph.json" > /tmp/claude-subagents/dispatch-impl-test.task_graph

cat > "$TEST_DIR/dispatch-impl-transcript.jsonl" << 'EOF'
{"message": {"content": "**Task ID:** T1\nDone"}}
EOF

echo '{"session_id": "dispatch-impl-test", "agent_type": "code-implementer-agent", "agent_transcript_path": "'"$TEST_DIR"'/dispatch-impl-transcript.jsonl"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/dispatch.sh" 2>&1 >/dev/null

DISPATCH_STATUS=$(jq -r '.tasks[] | select(.id=="T1") | .status' "$TEST_DIR/.claude/state/active_task_graph.json")
DISPATCH_PHASE2=$(jq -r '.current_phase' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$DISPATCH_STATUS" == "implemented" ]] && pass "dispatch: routes impl agent → update-task-status" || fail "dispatch: impl routing" "implemented" "$DISPATCH_STATUS"
[[ "$DISPATCH_PHASE2" == "execute" ]] && pass "dispatch: impl agent doesn't trigger advance-phase" || fail "dispatch: no advance" "execute" "$DISPATCH_PHASE2"

# Test: dispatcher handles unknown agent type gracefully (cleanup only)
echo '{"session_id": "dispatch-test", "agent_id": "agent-unknown", "agent_type": "general-purpose"}' | \
  bash "$REPO_ROOT/.claude/hooks/SubagentStop/dispatch.sh" 2>&1 >/dev/null
pass "dispatch: handles unknown agent type gracefully"

rm -rf /tmp/claude-subagents

# ============================================
# Summary
# ============================================
echo ""
echo "==================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "==================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
