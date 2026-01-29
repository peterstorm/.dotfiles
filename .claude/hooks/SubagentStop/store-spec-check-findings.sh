#!/bin/bash
# Auto-store spec-check findings when spec-check-invoker agent completes
# Parses output for CRITICAL/HIGH/MEDIUM findings and stores them
# Sets spec_check status in task graph
#
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

# Get agent type from stored file (set by SubagentStart hook)
AGENT_TYPE=""
if [[ -n "$AGENT_ID" && -f "/tmp/claude-subagents/${AGENT_ID}.type" ]]; then
  AGENT_TYPE=$(cat "/tmp/claude-subagents/${AGENT_ID}.type")
fi

# Only process spec-check-invoker agent
[[ "$AGENT_TYPE" != "spec-check-invoker" ]] && exit 0

# Read full transcript text from JSONL file
source ~/.claude/hooks/helpers/parse-transcript.sh
AGENT_OUTPUT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  AGENT_OUTPUT=$(parse_transcript "$TRANSCRIPT_PATH")
fi

[[ -z "$AGENT_OUTPUT" ]] && exit 0

echo "Processing spec-check findings..."

# Extract wave number
WAVE=$(echo "$AGENT_OUTPUT" | grep -oE 'SPEC_CHECK_WAVE: ([0-9]+)' | grep -oE '[0-9]+')
if [[ -z "$WAVE" ]]; then
  WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
fi

# Extract findings by severity
CRITICAL_FINDINGS=()
HIGH_FINDINGS=()
MEDIUM_FINDINGS=()

while IFS= read -r line; do
  if [[ "$line" =~ ^CRITICAL:\ *(.*) ]]; then
    CRITICAL_FINDINGS+=("${BASH_REMATCH[1]}")
  elif [[ "$line" =~ ^HIGH:\ *(.*) ]]; then
    HIGH_FINDINGS+=("${BASH_REMATCH[1]}")
  elif [[ "$line" =~ ^MEDIUM:\ *(.*) ]]; then
    MEDIUM_FINDINGS+=("${BASH_REMATCH[1]}")
  fi
done <<< "$AGENT_OUTPUT"

# Check for explicit counts
CRITICAL_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'SPEC_CHECK_CRITICAL_COUNT: ([0-9]+)' | grep -oE '[0-9]+')
HIGH_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'SPEC_CHECK_HIGH_COUNT: ([0-9]+)' | grep -oE '[0-9]+')
VERDICT=$(echo "$AGENT_OUTPUT" | grep -oE 'SPEC_CHECK_VERDICT: (PASSED|BLOCKED)' | sed 's/SPEC_CHECK_VERDICT: //')

# SAFETY: If no CRITICAL_COUNT found, output is malformed
if [[ -z "$CRITICAL_COUNT" ]]; then
  echo "WARNING: No SPEC_CHECK_CRITICAL_COUNT found in spec-check output"
  echo "Output may be malformed. NOT updating state."
  echo "Review the output manually and run /wave-gate again."
  exit 0
fi

# Build JSON arrays
CRITICAL_JSON=$(printf '%s\n' "${CRITICAL_FINDINGS[@]}" | jq -R . | jq -s .)
HIGH_JSON=$(printf '%s\n' "${HIGH_FINDINGS[@]}" | jq -R . | jq -s .)
MEDIUM_JSON=$(printf '%s\n' "${MEDIUM_FINDINGS[@]}" | jq -R . | jq -s .)

# Acquire lock for state file update
LOCK_FILE="$(dirname "$TASK_GRAPH")/.task_graph.lock"
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

# Update task graph with spec_check results
jq --argjson critical "$CRITICAL_JSON" \
   --argjson high "$HIGH_JSON" \
   --argjson medium "$MEDIUM_JSON" \
   --argjson critical_count "${CRITICAL_COUNT:-0}" \
   --argjson high_count "${HIGH_COUNT:-0}" \
   --arg verdict "${VERDICT:-UNKNOWN}" \
   --arg wave "$WAVE" '
  .spec_check = {
    wave: ($wave | tonumber),
    run_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    critical_count: $critical_count,
    high_count: $high_count,
    critical_findings: $critical,
    high_findings: $high,
    medium_findings: $medium,
    verdict: $verdict
  } |
  if $critical_count > 0 then
    .wave_gates[$wave].blocked = true
  else . end
' "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Stored spec-check findings: ${CRITICAL_COUNT:-0} critical, ${HIGH_COUNT:-0} high"
if [[ "${CRITICAL_COUNT:-0}" -gt 0 ]]; then
  echo "Wave $WAVE BLOCKED due to spec-check critical findings."
else
  echo "Spec-check passed for wave $WAVE."
fi

exit 0
