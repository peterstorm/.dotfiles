#!/bin/bash
# Auto-store findings when review agent completes
# Parses output for CRITICAL/ADVISORY findings and stores them
# Sets review_status per task (only way to mark reviews as done)
#
# Handles both agent types:
#   - review-invoker (spawned by wave-gate)
#   - task-reviewer (spawned by task-planner)
# Supports cross-repo: finds task graph via session-scoped path if not in cwd

# Read hook input from stdin
INPUT=$(cat)

# DEBUG: Log hook invocation
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings START" >> /tmp/claude-hooks-debug.log
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings INPUT=$INPUT" >> /tmp/claude-hooks-debug.log

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

# Resolve task graph path (supports cross-repo via session-scoped path)
source ~/.claude/hooks/helpers/resolve-task-graph.sh
TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
export TASK_GRAPH  # Export for helper script

# Get agent type directly from SubagentStop input (always available, no temp file needed)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings AGENT_ID=$AGENT_ID TYPE=$AGENT_TYPE" >> /tmp/claude-hooks-debug.log

# Only process review agents (both types)
case "$AGENT_TYPE" in
  task-reviewer|review-invoker) ;;
  *) exit 0 ;;
esac

# Read full transcript text from JSONL file
source ~/.claude/hooks/helpers/parse-transcript.sh
AGENT_OUTPUT=""
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings TRANSCRIPT_PATH=$TRANSCRIPT_PATH" >> /tmp/claude-hooks-debug.log
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings TRANSCRIPT_EXISTS=$(test -f "$TRANSCRIPT_PATH" && echo YES || echo NO)" >> /tmp/claude-hooks-debug.log
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  AGENT_OUTPUT=$(parse_transcript "$TRANSCRIPT_PATH")
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings PARSE_RESULT_LENGTH=${#AGENT_OUTPUT}" >> /tmp/claude-hooks-debug.log

[[ -z "$AGENT_OUTPUT" ]] && exit 0

echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings AGENT_OUTPUT_LENGTH=${#AGENT_OUTPUT}" >> /tmp/claude-hooks-debug.log

# Extract task ID from output — try multiple patterns
# Pattern 1: "--task T1" (review-invoker format)
TASK_ID=$(echo "$AGENT_OUTPUT" | grep -oE '\-\-task T[0-9]+' | head -1 | sed 's/--task //')

# Pattern 2: "## Review: T1" (task-reviewer format)
if [[ -z "$TASK_ID" ]]; then
  TASK_ID=$(echo "$AGENT_OUTPUT" | grep -oE '## Review: (T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')
fi

# Pattern 3+: Use flexible helper (handles many formats)
if [[ -z "$TASK_ID" ]]; then
  source ~/.claude/hooks/helpers/extract-task-id.sh
  TASK_ID=$(extract_task_id "$AGENT_OUTPUT")
fi

[[ -z "$TASK_ID" ]] && exit 0

echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings TASK_ID=$TASK_ID" >> /tmp/claude-hooks-debug.log

echo "Processing review findings for $TASK_ID ($AGENT_TYPE)..."

# Check if /review-pr skill was invoked
if ! echo "$AGENT_OUTPUT" | grep -qiE '(review-pr|/review-pr|Launching skill)'; then
  echo "WARNING: $AGENT_TYPE for $TASK_ID may not have invoked /review-pr skill"
  echo "Proceeding with output parsing..."
fi

# Extract findings sections
CRITICAL_SECTION=$(echo "$AGENT_OUTPUT" | sed -n '/### Critical Findings/,/### /p' | grep -E '^- \*\*|^- [A-Z]' | sed 's/^- //')
ADVISORY_SECTION=$(echo "$AGENT_OUTPUT" | sed -n '/### Advisory Findings/,/### /p' | grep -E '^- \*\*|^- [A-Z]' | sed 's/^- //')

# Build findings for store script
FINDINGS=""

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" == "None" ]] && continue
  FINDINGS+="CRITICAL: $line"$'\n'
done <<< "$CRITICAL_SECTION"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" == "None" ]] && continue
  FINDINGS+="ADVISORY: $line"$'\n'
done <<< "$ADVISORY_SECTION"

# Check for explicit Summary counts
CRITICAL_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'CRITICAL_COUNT: ([0-9]+)' | grep -oE '[0-9]+' | tail -1)
ADVISORY_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'ADVISORY_COUNT: ([0-9]+)' | grep -oE '[0-9]+' | tail -1)

echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings CRITICAL_COUNT=$CRITICAL_COUNT ADVISORY_COUNT=$ADVISORY_COUNT" >> /tmp/claude-hooks-debug.log
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings FINDINGS_LENGTH=${#FINDINGS}" >> /tmp/claude-hooks-debug.log
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings FINDINGS_CONTENT='$(echo "$FINDINGS" | head -c 200 | tr '\n' '|')'" >> /tmp/claude-hooks-debug.log

# SAFETY: If no CRITICAL_COUNT found, mark as evidence_capture_failed (not silent exit!)
if [[ -z "$CRITICAL_COUNT" ]]; then
  echo "WARNING: No CRITICAL_COUNT found in $AGENT_TYPE output for $TASK_ID"
  echo "Marking as evidence_capture_failed so /wave-gate can surface the issue."

  # Acquire lock and write explicit failure state
  source ~/.claude/hooks/helpers/lock.sh
  LOCK_FILE="$(dirname "$TASK_GRAPH")/.task_graph.lock"
  acquire_lock "$LOCK_FILE" auto

  jq "
    .tasks |= map(if .id == \"$TASK_ID\" then
      .review_status = \"evidence_capture_failed\" |
      .review_error = \"CRITICAL_COUNT marker not found in agent output - re-run /wave-gate\"
    else . end)
  " "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

  echo "Task $TASK_ID review_status set to evidence_capture_failed"
  exit 0
fi

# DEBUG: Log decision conditions
echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings DECISION: FINDINGS_NON_EMPTY=$([[ -n "$FINDINGS" ]] && echo YES || echo NO) CRITICAL_COUNT_IS_ZERO=$([[ "$CRITICAL_COUNT" -eq 0 ]] && echo YES || echo NO)" >> /tmp/claude-hooks-debug.log

# Store findings via helper script (which sets review_status)
if [[ -n "$FINDINGS" ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings BRANCH=has_findings" >> /tmp/claude-hooks-debug.log
  echo "$FINDINGS" | bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID"
elif [[ "$CRITICAL_COUNT" -eq 0 ]]; then
  # Explicit CRITICAL_COUNT: 0 - safe to mark as passed
  echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings BRANCH=zero_critical_passed" >> /tmp/claude-hooks-debug.log
  echo "No critical findings for $TASK_ID (CRITICAL_COUNT: 0) - marking as passed"
  bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID" <<< ""
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') store-reviewer-findings BRANCH=parsing_failed_blocked" >> /tmp/claude-hooks-debug.log
  echo "ERROR: CRITICAL_COUNT: $CRITICAL_COUNT but no findings parsed for $TASK_ID"
  echo "Marking as BLOCKED to be safe."
  echo "CRITICAL: Review output parsing failed - $CRITICAL_COUNT findings not captured" | \
    bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID"
fi

exit 0
