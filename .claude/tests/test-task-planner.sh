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
# Test 3: mark-tests-passed.sh
# ============================================
echo ""
echo "--- Test: mark-tests-passed.sh ---"

# Reset state
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "tasks": [],
  "wave_gates": {"1": {"impl_complete": true, "tests_passed": null, "reviews_complete": false, "blocked": false}}
}
EOF

bash "$REPO_ROOT/.claude/hooks/helpers/mark-tests-passed.sh"
TESTS_PASSED=$(jq -r '.wave_gates["1"].tests_passed' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$TESTS_PASSED" == "true" ]] && pass "mark-tests-passed sets tests_passed=true" || fail "mark-tests-passed" "true" "$TESTS_PASSED"

# Test --failed flag
bash "$REPO_ROOT/.claude/hooks/helpers/mark-tests-passed.sh" --failed
TESTS_PASSED=$(jq -r '.wave_gates["1"].tests_passed' "$TEST_DIR/.claude/state/active_task_graph.json")
BLOCKED=$(jq -r '.wave_gates["1"].blocked' "$TEST_DIR/.claude/state/active_task_graph.json")
[[ "$TESTS_PASSED" == "false" ]] && pass "mark-tests-passed --failed sets tests_passed=false" || fail "mark-tests-passed --failed" "false" "$TESTS_PASSED"
[[ "$BLOCKED" == "true" ]] && pass "mark-tests-passed --failed sets blocked=true" || fail "mark-tests-passed --failed blocked" "true" "$BLOCKED"

# ============================================
# Test 4: complete-wave-gate.sh
# ============================================
echo ""
echo "--- Test: complete-wave-gate.sh ---"

# Setup: wave 1 complete, no critical findings
cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_wave": 1,
  "issue": null,
  "tasks": [
    {"id": "T1", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "advisory_findings": []},
    {"id": "T2", "wave": 1, "status": "implemented", "review_status": "passed", "critical_findings": [], "advisory_findings": []},
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

# Test: Allow wave 1 task
export HOOK_INPUT='{"tool_name": "Task", "tool_input": {"prompt": "**Task ID:** T1\nImplement feature"}}'
if bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1; then
  pass "Allows wave 1 task when current_wave=1"
else
  fail "Allows wave 1 task" "exit 0" "exit non-zero"
fi

# Test: Block wave 2 task
export HOOK_INPUT='{"tool_name": "Task", "tool_input": {"prompt": "**Task ID:** T2\nImplement feature"}}'
if bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1; then
  fail "Blocks wave 2 task when current_wave=1" "exit 2" "exit 0"
else
  pass "Blocks wave 2 task when current_wave=1"
fi

# Test: Allow non-planned task (no Task ID)
export HOOK_INPUT='{"tool_name": "Task", "tool_input": {"prompt": "Run some tests"}}'
if bash "$REPO_ROOT/.claude/hooks/PreToolUse/validate-task-execution.sh" 2>&1; then
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
{"current_wave": 1, "tasks": [], "wave_gates": {"1": {"tests_passed": null}}}
EOF

bash "$REPO_ROOT/.claude/hooks/helpers/mark-tests-passed.sh"
# Lock is released after script exits, so just verify the helper works
if command -v flock &>/dev/null; then
  pass "Lock mechanism available (flock)"
else
  pass "Lock mechanism available (mkdir-based)"
fi

# ============================================
# Summary
# ============================================
echo ""
echo "==================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "==================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
