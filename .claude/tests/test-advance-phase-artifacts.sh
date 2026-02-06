#!/bin/bash
# Tests for advance-phase.sh SubagentStop hook - specifically artifact capture
# Run: bash .claude/tests/test-advance-phase-artifacts.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/SubagentStop/advance-phase.sh"
TEST_DIR=$(mktemp -d)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0

setup() {
  mkdir -p "$TEST_DIR/.claude/state"
  mkdir -p "$TEST_DIR/.claude/specs/2025-01-15-auth"
  mkdir -p "$TEST_DIR/.claude/plans"
  
  # Create minimal state file
  cat > "$TEST_DIR/.claude/state/active_task_graph.json" << 'EOF'
{
  "current_phase": "specify",
  "phase_artifacts": {},
  "skipped_phases": [],
  "spec_file": null,
  "plan_file": null
}
EOF
  chmod 644 "$TEST_DIR/.claude/state/active_task_graph.json"
  
  # Create spec file
  echo "# Spec" > "$TEST_DIR/.claude/specs/2025-01-15-auth/spec.md"
  
  # Create plan file  
  echo "# Plan" > "$TEST_DIR/.claude/plans/2025-01-15-auth.md"
  
  cd "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

create_transcript() {
  local transcript_file="$1"
  local spec_path="$2"
  local plan_path="$3"
  
  mkdir -p "$(dirname "$transcript_file")"
  
  local content=""
  
  if [[ -n "$spec_path" ]]; then
    content+='{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"'"$spec_path"'"}}]}}'
    content+=$'\n'
  fi
  
  if [[ -n "$plan_path" ]]; then
    content+='{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"'"$plan_path"'"}}]}}'
    content+=$'\n'
  fi
  
  echo -n "$content" > "$transcript_file"
}

assert_field() {
  local expected=$1
  local field=$2
  local name=$3
  local actual
  actual=$(jq -r "$field" "$TEST_DIR/.claude/state/active_task_graph.json")
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}✓${NC} $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}✗${NC} $name (expected '$expected', got '$actual')"
  fi
}

# ===== TEST CASES =====

test_captures_spec_file_from_transcript() {
  setup
  
  local transcript="$TEST_DIR/transcript.jsonl"
  local spec_path="$TEST_DIR/.claude/specs/2025-01-15-auth/spec.md"
  create_transcript "$transcript" "$spec_path" ""
  
  # Simulate specify-agent completion
  local input
  input=$(jq -n \
    --arg session "test-session-1" \
    --arg agent "specify-agent" \
    --arg transcript "$transcript" \
    '{session_id: $session, agent_type: $agent, agent_transcript_path: $transcript}')
  
  echo "$input" | bash "$HOOK" 2>/dev/null
  
  assert_field "$spec_path" '.spec_file' "captures spec_file from transcript"
  
  teardown
}

test_captures_plan_file_from_transcript() {
  setup
  
  # Set phase to architecture
  jq '.current_phase = "architecture"' "$TEST_DIR/.claude/state/active_task_graph.json" > "$TEST_DIR/tmp.json"
  mv "$TEST_DIR/tmp.json" "$TEST_DIR/.claude/state/active_task_graph.json"
  
  local transcript="$TEST_DIR/transcript.jsonl"
  local plan_path="$TEST_DIR/.claude/plans/2025-01-15-auth.md"
  create_transcript "$transcript" "" "$plan_path"
  
  # Simulate architecture-agent completion
  local input
  input=$(jq -n \
    --arg session "test-session-2" \
    --arg agent "architecture-agent" \
    --arg transcript "$transcript" \
    '{session_id: $session, agent_type: $agent, agent_transcript_path: $transcript}')
  
  echo "$input" | bash "$HOOK" 2>/dev/null
  
  assert_field "$plan_path" '.plan_file' "captures plan_file from transcript"
  
  teardown
}

test_does_not_overwrite_existing_spec_file() {
  setup
  
  # Pre-set spec_file
  local existing_spec="$TEST_DIR/.claude/specs/existing/spec.md"
  mkdir -p "$(dirname "$existing_spec")"
  echo "# Existing" > "$existing_spec"
  jq --arg spec "$existing_spec" '.spec_file = $spec' "$TEST_DIR/.claude/state/active_task_graph.json" > "$TEST_DIR/tmp.json"
  mv "$TEST_DIR/tmp.json" "$TEST_DIR/.claude/state/active_task_graph.json"
  
  local transcript="$TEST_DIR/transcript.jsonl"
  local new_spec="$TEST_DIR/.claude/specs/2025-01-15-auth/spec.md"
  create_transcript "$transcript" "$new_spec" ""
  
  local input
  input=$(jq -n \
    --arg session "test-session-3" \
    --arg agent "specify-agent" \
    --arg transcript "$transcript" \
    '{session_id: $session, agent_type: $agent, agent_transcript_path: $transcript}')
  
  echo "$input" | bash "$HOOK" 2>/dev/null
  
  # Should keep existing, not overwrite
  assert_field "$existing_spec" '.spec_file' "does not overwrite existing spec_file"
  
  teardown
}

test_ignores_non_spec_paths() {
  setup
  
  local transcript="$TEST_DIR/transcript.jsonl"
  # Write to a non-.claude/specs path
  cat > "$transcript" << 'EOF'
{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/src/auth.ts"}}]}}
EOF
  
  local input
  input=$(jq -n \
    --arg session "test-session-4" \
    --arg agent "specify-agent" \
    --arg transcript "$transcript" \
    '{session_id: $session, agent_type: $agent, agent_transcript_path: $transcript}')
  
  echo "$input" | bash "$HOOK" 2>/dev/null
  
  assert_field "null" '.spec_file' "ignores non-.claude/specs paths"
  
  teardown
}

test_ignores_non_existent_files() {
  setup
  
  local transcript="$TEST_DIR/transcript.jsonl"
  # Reference a file that doesn't exist on disk
  cat > "$transcript" << 'EOF'
{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/nonexistent/.claude/specs/test/spec.md"}}]}}
EOF
  
  local input
  input=$(jq -n \
    --arg session "test-session-5" \
    --arg agent "specify-agent" \
    --arg transcript "$transcript" \
    '{session_id: $session, agent_type: $agent, agent_transcript_path: $transcript}')
  
  echo "$input" | bash "$HOOK" 2>/dev/null
  
  assert_field "null" '.spec_file' "ignores paths where file doesn't exist"
  
  teardown
}

# ===== RUN TESTS =====

echo "Testing advance-phase.sh artifact capture"
echo "========================================="
echo ""

test_captures_spec_file_from_transcript
test_captures_plan_file_from_transcript
test_does_not_overwrite_existing_spec_file
test_ignores_non_spec_paths
test_ignores_non_existent_files

echo ""
echo "========================================="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
