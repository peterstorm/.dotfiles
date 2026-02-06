#!/bin/bash
# Auto-store findings when review agent completes
# Parses output for CRITICAL/ADVISORY findings and stores them
# Sets review_status per task (only way to mark reviews as done)
#
# Handles review-invoker agent (spawned by wave-gate)
# Supports cross-repo: finds task graph via session-scoped path if not in cwd

# Read hook input from stdin
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

# Resolve task graph path (supports cross-repo via session-scoped path)
source ~/.claude/hooks/helpers/resolve-task-graph.sh
TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
export TASK_GRAPH  # Export for helper script

# Get agent type directly from SubagentStop input (always available, no temp file needed)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# Only process review agents (both types)
case "$AGENT_TYPE" in
  review-invoker) ;;
  *) exit 0 ;;
esac

# Read full transcript text from JSONL file
source ~/.claude/hooks/helpers/parse-transcript.sh
AGENT_OUTPUT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  AGENT_OUTPUT=$(parse_transcript "$TRANSCRIPT_PATH")
fi
[[ -z "$AGENT_OUTPUT" ]] && exit 0

# Extract task ID from output — try multiple patterns
# Pattern 1: "--task T1" (review-invoker format)
TASK_ID=$(echo "$AGENT_OUTPUT" | grep -oE '\-\-task T[0-9]+' | head -1 | sed 's/--task //')

# Pattern 2: Use flexible helper (handles many formats)
if [[ -z "$TASK_ID" ]]; then
  source ~/.claude/hooks/helpers/extract-task-id.sh
  TASK_ID=$(extract_task_id "$AGENT_OUTPUT")
fi

[[ -z "$TASK_ID" ]] && exit 0

echo "Processing review findings for $TASK_ID ($AGENT_TYPE)..."

# --- Parse ### Machine Summary block (standardized format) ---
# Primary: parse structured Machine Summary block
# Fallback: legacy free-text parsing if Machine Summary absent

MACHINE_SUMMARY=$(echo "$AGENT_OUTPUT" | sed -n '/^### Machine Summary/,/^###\|^$/p')
FINDINGS=""
CRITICAL_COUNT=""
ADVISORY_COUNT=""

if [[ -n "$MACHINE_SUMMARY" ]]; then
  # Parse from standardized Machine Summary block
  CRITICAL_COUNT=$(echo "$MACHINE_SUMMARY" | grep -oE '^CRITICAL_COUNT: ([0-9]+)' | grep -oE '[0-9]+' | tail -1)
  ADVISORY_COUNT=$(echo "$MACHINE_SUMMARY" | grep -oE '^ADVISORY_COUNT: ([0-9]+)' | grep -oE '[0-9]+' | tail -1)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^CRITICAL:\ *(.*) ]]; then
      FINDINGS+="CRITICAL: ${BASH_REMATCH[1]}"$'\n'
    elif [[ "$line" =~ ^ADVISORY:\ *(.*) ]]; then
      FINDINGS+="ADVISORY: ${BASH_REMATCH[1]}"$'\n'
    fi
  done <<< "$MACHINE_SUMMARY"
else
  # Fallback: legacy parsing (review-pr output without Machine Summary)
  echo "WARNING: No ### Machine Summary block found — using legacy parsing"

  CRITICAL_SECTION=$(echo "$AGENT_OUTPUT" | sed -n '/### Critical Findings/,/### /p' | grep -E '^- \*\*|^- [A-Z]' | sed 's/^- //')
  ADVISORY_SECTION=$(echo "$AGENT_OUTPUT" | sed -n '/### Advisory Findings/,/### /p' | grep -E '^- \*\*|^- [A-Z]' | sed 's/^- //')

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

  CRITICAL_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'CRITICAL_COUNT: ([0-9]+)' | grep -oE '[0-9]+' | tail -1)
  ADVISORY_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'ADVISORY_COUNT: ([0-9]+)' | grep -oE '[0-9]+' | tail -1)
fi

# SAFETY: If no CRITICAL_COUNT found, mark as evidence_capture_failed (not silent exit!)
if [[ -z "$CRITICAL_COUNT" ]]; then
  echo "WARNING: No CRITICAL_COUNT found in $AGENT_TYPE output for $TASK_ID"
  echo "Marking as evidence_capture_failed so /wave-gate can surface the issue."

  # Write explicit failure state
  bash ~/.claude/hooks/helpers/state-file-write.sh --arg task_id "$TASK_ID" '
    .tasks |= map(if .id == $task_id then
      .review_status = "evidence_capture_failed" |
      .review_error = "CRITICAL_COUNT marker not found in agent output - re-run /wave-gate"
    else . end)
  '

  echo "Task $TASK_ID review_status set to evidence_capture_failed"
  exit 0
fi

# Store findings via helper script (which sets review_status)
if [[ -n "$FINDINGS" ]]; then
  echo "$FINDINGS" | bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID"
elif [[ "$CRITICAL_COUNT" -eq 0 ]]; then
  # Explicit CRITICAL_COUNT: 0 - safe to mark as passed
  echo "No critical findings for $TASK_ID (CRITICAL_COUNT: 0) - marking as passed"
  bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID" <<< ""
else
  echo "ERROR: CRITICAL_COUNT: $CRITICAL_COUNT but no findings parsed for $TASK_ID"
  echo "Marking as BLOCKED to be safe."
  echo "CRITICAL: Review output parsing failed - $CRITICAL_COUNT findings not captured" | \
    bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID"
fi

exit 0
