#!/bin/bash
# Store review findings for a task
#
# Usage (stdin - preferred):
#   bash store-review-findings.sh --task T1 <<'EOF'
#   CRITICAL: SQL injection in query builder
#   CRITICAL: Missing auth check on endpoint
#   ADVISORY: Consider extracting validation
#   EOF
#
# Usage (CLI args - legacy, avoid special chars):
#   bash store-review-findings.sh --task T1 --critical "issue" --advisory "suggestion"

set -e

TASK_GRAPH=".claude/state/active_task_graph.json"
LOCK_FILE=".claude/state/.task_graph.lock"

[[ ! -f "$TASK_GRAPH" ]] && { echo "ERROR: No active task graph"; exit 1; }

TASK_ID=""
CRITICAL=()
ADVISORY=()

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK_ID="$2"; shift 2 ;;
    --critical) CRITICAL+=("$2"); shift 2 ;;
    --advisory) ADVISORY+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$TASK_ID" ]] && { echo "ERROR: --task required"; exit 1; }

# Read from stdin if available (preferred method)
if [[ ! -t 0 ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^CRITICAL:\ *(.*) ]]; then
      CRITICAL+=("${BASH_REMATCH[1]}")
    elif [[ "$line" =~ ^ADVISORY:\ *(.*) ]]; then
      ADVISORY+=("${BASH_REMATCH[1]}")
    fi
  done
fi

# Acquire cross-platform lock
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

# Build JSON arrays using jq for proper escaping
CRITICAL_JSON="[]"
ADVISORY_JSON="[]"

if [[ ${#CRITICAL[@]} -gt 0 ]]; then
  CRITICAL_JSON=$(printf '%s\n' "${CRITICAL[@]}" | jq -R . | jq -s .)
fi

if [[ ${#ADVISORY[@]} -gt 0 ]]; then
  ADVISORY_JSON=$(printf '%s\n' "${ADVISORY[@]}" | jq -R . | jq -s .)
fi

# Update task with findings
jq --argjson critical "$CRITICAL_JSON" --argjson advisory "$ADVISORY_JSON" "
  .tasks |= map(
    if .id == \"$TASK_ID\" then
      .critical_findings = \$critical |
      .advisory_findings = \$advisory |
      .review_status = (if (\$critical | length) > 0 then \"blocked\" else \"passed\" end)
    else . end
  )
" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Stored findings for $TASK_ID: ${#CRITICAL[@]} critical, ${#ADVISORY[@]} advisory"

# Update wave blocked status if critical findings
if [[ ${#CRITICAL[@]} -gt 0 ]]; then
  WAVE=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .wave" "$TASK_GRAPH")
  jq ".wave_gates[\"$WAVE\"].blocked = true" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"
  echo "Wave $WAVE BLOCKED due to critical findings."
fi

exit 0
