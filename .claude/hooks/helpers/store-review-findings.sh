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

# Use exported TASK_GRAPH if available (cross-repo), fallback to local
TASK_GRAPH="${TASK_GRAPH:-.claude/state/active_task_graph.json}"
export TASK_GRAPH

[[ ! -f "$TASK_GRAPH" ]] && { echo "ERROR: No active task graph at $TASK_GRAPH"; exit 1; }

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

# Build JSON arrays using jq for proper escaping
CRITICAL_JSON="[]"
ADVISORY_JSON="[]"

if [[ ${#CRITICAL[@]} -gt 0 ]]; then
  CRITICAL_JSON=$(printf '%s\n' "${CRITICAL[@]}" | jq -R . | jq -s .)
fi

if [[ ${#ADVISORY[@]} -gt 0 ]]; then
  ADVISORY_JSON=$(printf '%s\n' "${ADVISORY[@]}" | jq -R . | jq -s .)
fi

# Update task with findings via state-file-write
export TASK_GRAPH
bash ~/.claude/hooks/helpers/state-file-write.sh \
  --argjson critical "$CRITICAL_JSON" \
  --argjson advisory "$ADVISORY_JSON" \
  --arg task_id "$TASK_ID" '
  .tasks |= map(
    if .id == $task_id then
      .critical_findings = $critical |
      .advisory_findings = $advisory |
      .review_status = (if ($critical | length) > 0 then "blocked" else "passed" end)
    else . end
  )
'

echo "Stored findings for $TASK_ID: ${#CRITICAL[@]} critical, ${#ADVISORY[@]} advisory"

# Update wave blocked status if critical findings
if [[ ${#CRITICAL[@]} -gt 0 ]]; then
  WAVE=$(jq -r ".tasks[] | select(.id==\"$TASK_ID\") | .wave" "$TASK_GRAPH")
  bash ~/.claude/hooks/helpers/state-file-write.sh --arg wave "$WAVE" '.wave_gates[$wave].blocked = true'
  echo "Wave $WAVE BLOCKED due to critical findings."
fi

exit 0
