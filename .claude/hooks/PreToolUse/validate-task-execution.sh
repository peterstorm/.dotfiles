#!/bin/bash
# Combined hook: validates wave order AND review gate
# Replaces: validate-wave.sh + require-review-gate.sh
# Only active when task graph exists
#
# WHY LOCAL PATH (not resolve-task-graph.sh):
# PreToolUse hooks enforce restrictions only within the orchestrated repo.
# If cwd is a different repo, task graph won't exist → exit 0 → allow.
# This is correct: wave validation only applies to tasks in the current
# orchestration. Cross-repo resolution is only needed for SubagentStop
# hooks that UPDATE the task graph from any context.
#
# NOTE: Exit code 2 requires stderr output, NOT stdout!
# NOTE: Hook input comes via stdin, not env var!

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Read hook input from stdin (Claude Code pipes JSON to stdin)
INPUT=$(cat)

# Only check Task tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Task" ]] && exit 0

# Extract task ID from prompt using flexible helper
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty')

source ~/.claude/hooks/helpers/extract-task-id.sh
TASK_ID=$(extract_task_id "$PROMPT")
[[ -z "$TASK_ID" ]] && exit 0  # Not a planned task, allow

# Enforce canonical format: **Task ID:** T1
validate_task_id_format "$PROMPT"
FORMAT_STATUS=$?
if [[ "$FORMAT_STATUS" -eq 1 ]]; then
  # Non-canonical format detected - BLOCK and show correct format
  echo "BLOCKED: Non-canonical Task ID format detected." >&2
  echo "" >&2
  echo "Found task: $TASK_ID" >&2
  echo "Required format: $(canonical_format "$TASK_ID")" >&2
  echo "" >&2
  echo "The prompt MUST use exactly:" >&2
  echo "  **Task ID:** $TASK_ID" >&2
  echo "" >&2
  echo "This ensures test capture and status tracking work correctly." >&2
  exit 2
fi

# Single jq query to get all needed data
read -r CURRENT_WAVE TASK_WAVE TASK_STATUS TASK_DEPS < <(
  jq -r --arg id "$TASK_ID" '
    (.current_wave | tostring) + " " +
    ((.tasks[] | select(.id==$id) | .wave | tostring) // "") + " " +
    ((.tasks[] | select(.id==$id) | .status) // "") + " " +
    ((.tasks[] | select(.id==$id) | .depends_on | join(",")) // "")
  ' "$TASK_GRAPH"
)

[[ -z "$TASK_WAVE" ]] && exit 0  # Task not in graph, allow

# === Check 1: Wave order ===
if [[ "$TASK_WAVE" -gt "$CURRENT_WAVE" ]]; then
  echo "BLOCKED: Cannot execute $TASK_ID (wave $TASK_WAVE) - current wave is $CURRENT_WAVE" >&2
  echo "Complete all wave $CURRENT_WAVE tasks first." >&2
  exit 2
fi

# === Check 2: Dependencies complete ===
if [[ -n "$TASK_DEPS" ]]; then
  IFS=',' read -ra DEPS <<< "$TASK_DEPS"
  for dep in "${DEPS[@]}"; do
    DEP_STATUS=$(jq -r ".tasks[] | select(.id==\"$dep\") | .status" "$TASK_GRAPH")
    if [[ "$DEP_STATUS" != "completed" ]]; then
      echo "BLOCKED: Cannot execute $TASK_ID - dependency $dep not complete (status: $DEP_STATUS)" >&2
      exit 2
    fi
  done
fi

# === Check 3: Previous wave review gate (only for wave > 1) ===
if [[ "$TASK_WAVE" -eq "$CURRENT_WAVE" && "$CURRENT_WAVE" -gt 1 ]]; then
  PREV_WAVE=$((CURRENT_WAVE - 1))

  read -r PREV_REVIEWS_COMPLETE PREV_BLOCKED PREV_TESTS < <(
    jq -r "
      .wave_gates[\"$PREV_WAVE\"] |
      (.reviews_complete // false | tostring) + \" \" +
      (.blocked // false | tostring) + \" \" +
      (.tests_passed // \"null\" | tostring)
    " "$TASK_GRAPH"
  )

  if [[ "$PREV_REVIEWS_COMPLETE" != "true" ]]; then
    echo "BLOCKED: Wave $PREV_WAVE review gate not passed." >&2
    echo "" >&2
    if [[ "$PREV_BLOCKED" == "true" ]]; then
      echo "Wave $PREV_WAVE is BLOCKED due to:" >&2
      [[ "$PREV_TESTS" == "false" ]] && echo "  - Integration tests failed" >&2
      CRITICAL=$(jq -r "[.tasks[] | select(.wave == $PREV_WAVE) | .critical_findings // [] | length] | add // 0" "$TASK_GRAPH")
      [[ "$CRITICAL" -gt 0 ]] && echo "  - $CRITICAL critical review findings" >&2
    else
      echo "Wave $PREV_WAVE gates not yet run." >&2
    fi
    echo "" >&2
    echo "Run: /wave-gate" >&2
    exit 2
  fi
fi

# === Store baseline SHA for per-task new-test detection ===
# verify-new-tests.sh diffs against this SHA (not branch merge-base) to scope
# new-test detection to changes made by THIS task, not the whole branch.
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
if [[ -n "$HEAD_SHA" && -n "$TASK_ID" ]]; then
  source ~/.claude/hooks/helpers/lock.sh
  LOCK_FILE=".claude/state/.task_graph.lock"
  acquire_lock "$LOCK_FILE" auto
  jq --arg id "$TASK_ID" --arg sha "$HEAD_SHA" '
    .tasks |= map(if .id == $id then .start_sha = $sha else . end)
  ' "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"
fi

exit 0
