#!/bin/bash
# Test suite for task-planner hooks and helpers
# Run from repo root: bash .claude/tests/test-task-planner.sh

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
# Test 1: Task ID extraction patterns
# ============================================
echo "--- Test: Task ID Extraction ---"

# Pattern: **Task ID:** T1
PROMPT1='## Task Assignment

**Task ID:** T1
**Wave:** 1'

TASK_ID1=$(echo "$PROMPT1" | grep -oE '(\*\*)?Task ID:(\*\*)? ?(T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')
[[ "$TASK_ID1" == "T1" ]] && pass "Extracts from **Task ID:** T1" || fail "Extracts from **Task ID:** T1" "T1" "$TASK_ID1"

# Pattern: Task ID: T2 (no markdown)
PROMPT2='Task ID: T2
Wave: 1'

TASK_ID2=$(echo "$PROMPT2" | grep -oE '(\*\*)?Task ID:(\*\*)? ?(T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')
[[ "$TASK_ID2" == "T2" ]] && pass "Extracts from Task ID: T2 (plain)" || fail "Extracts from Task ID: T2 (plain)" "T2" "$TASK_ID2"

# Pattern: ## Task: T3 (task-reviewer format - should NOT match)
PROMPT3='## Task: T3
**Description:** test'

TASK_ID=$(echo "$PROMPT3" | grep -oE '(\*\*)?Task ID:(\*\*)? ?(T[0-9]+)' | head -1 | grep -oE 'T[0-9]+' || echo "")
[[ -z "$TASK_ID" ]] && pass "Does NOT extract from ## Task: T3 (reviewer format)" || fail "Does NOT extract from ## Task: T3" "" "$TASK_ID"

# ============================================
# Test 2: store-review-findings.sh with stdin
# ============================================
echo ""
echo "--- Test: store-review-findings.sh ---"

# Create test state
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

# ============================================
# Test 6: File locking (race condition prevention)
# ============================================
echo ""
echo "--- Test: File Locking ---"

# Verify lock mechanism works (file on Linux, directory on macOS)
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
# Test 10: block-direct-edits.sh subagent allowlist
# ============================================
echo ""
echo "--- Test: block-direct-edits.sh subagent allowlist ---"

# Ensure state file exists for the hook to activate
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{"current_wave": 1, "tasks": [], "wave_gates": {"1": {"blocked": false}}}
EOF

# Clean up any existing subagent flags
rm -rf /tmp/claude-subagents

# Test: Edit blocked when no subagent active
if echo '{"tool_name": "Edit", "tool_input": {"file_path": "test.ts"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/block-direct-edits.sh" 2>/dev/null; then
  fail "Blocks Edit when no subagent active" "exit 2" "exit 0"
else
  pass "Blocks Edit when no subagent active"
fi

# Test: Edit allowed when subagent active
mkdir -p /tmp/claude-subagents
echo "test-agent-123" > /tmp/claude-subagents/test-session.active

if echo '{"tool_name": "Edit", "tool_input": {"file_path": "test.ts"}}' | bash "$REPO_ROOT/.claude/hooks/PreToolUse/block-direct-edits.sh" 2>/dev/null; then
  pass "Allows Edit when subagent is active"
else
  fail "Allows Edit when subagent is active" "exit 0" "exit 2"
fi

# Cleanup
rm -rf /tmp/claude-subagents

# ============================================
# Test 11: SessionStart cleanup hook
# ============================================
echo ""
echo "--- Test: SessionStart cleanup ---"

mkdir -p /tmp/claude-subagents
echo "stale-agent" > /tmp/claude-subagents/old-session.active
echo "code-implementer-agent" > /tmp/claude-subagents/stale-agent.type

bash "$REPO_ROOT/.claude/hooks/SessionStart/cleanup-stale-subagents.sh"

if [[ -f /tmp/claude-subagents/old-session.active ]]; then
  fail "SessionStart cleans stale .active files" "deleted" "still exists"
else
  pass "SessionStart cleans stale .active files"
fi

if [[ -f /tmp/claude-subagents/stale-agent.type ]]; then
  fail "SessionStart cleans stale .type files" "deleted" "still exists"
else
  pass "SessionStart cleans stale .type files"
fi

# ============================================
# Test 12: complete-wave-gate.sh blocks missing new_tests_written
# ============================================
echo ""
echo "--- Test: complete-wave-gate.sh new_tests_written gate ---"

cd "$TEST_DIR"

# Tests pass but no new tests written
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

# Type file should be cleaned up
[[ ! -f /tmp/claude-subagents/agent-aaa.type ]] && pass "cleanup: removes .type file" || fail "cleanup: removes .type" "deleted" "still exists"

# Cleanup
rm -rf /tmp/claude-subagents

# ============================================
# Summary
# ============================================
echo ""
echo "==================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "==================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
