#!/bin/bash
# Auto-store findings when task-reviewer agent completes
# Parses output for CRITICAL/ADVISORY findings and stores them
# This ensures blocked status is set automatically

TASK_GRAPH=".claude/state/active_task_graph.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Get agent output from hook input
AGENT_OUTPUT=$(echo "$HOOK_INPUT" | jq -r '.stdout // .transcript // empty' 2>/dev/null)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.subagent_type // empty' 2>/dev/null)

# Only process task-reviewer agents
[[ "$AGENT_TYPE" != "task-reviewer" ]] && exit 0

# Extract task ID from output (## Review: T1)
TASK_ID=$(echo "$AGENT_OUTPUT" | grep -oE '## Review: (T[0-9]+)' | head -1 | grep -oE 'T[0-9]+')
[[ -z "$TASK_ID" ]] && exit 0

echo "Processing review findings for $TASK_ID..."

# Check if /review-pr skill was invoked (look for skill invocation markers)
# The Skill tool output typically contains "Launching skill: review-pr" or similar
if ! echo "$AGENT_OUTPUT" | grep -qiE '(review-pr|/review-pr|Launching skill)'; then
  echo "WARNING: task-reviewer for $TASK_ID may not have invoked /review-pr skill"
  echo "Check if the agent followed instructions. Proceeding with output parsing..."
fi

# Extract findings sections
# Look for lines starting with "- " after "### Critical Findings" until next "###"
CRITICAL_SECTION=$(echo "$AGENT_OUTPUT" | sed -n '/### Critical Findings/,/### /p' | grep -E '^- \*\*|^- [A-Z]' | sed 's/^- //')
ADVISORY_SECTION=$(echo "$AGENT_OUTPUT" | sed -n '/### Advisory Findings/,/### /p' | grep -E '^- \*\*|^- [A-Z]' | sed 's/^- //')

# Build findings for store script
FINDINGS=""

# Process critical findings
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" == "None" ]] && continue
  FINDINGS+="CRITICAL: $line"$'\n'
done <<< "$CRITICAL_SECTION"

# Process advisory findings
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" == "None" ]] && continue
  FINDINGS+="ADVISORY: $line"$'\n'
done <<< "$ADVISORY_SECTION"

# Check for explicit Summary counts (REQUIRED in task-reviewer output)
CRITICAL_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'CRITICAL_COUNT: ([0-9]+)' | grep -oE '[0-9]+')
ADVISORY_COUNT=$(echo "$AGENT_OUTPUT" | grep -oE 'ADVISORY_COUNT: ([0-9]+)' | grep -oE '[0-9]+')

# SAFETY: If no Summary section found, DON'T assume passed - output is malformed
if [[ -z "$CRITICAL_COUNT" ]]; then
  echo "WARNING: No CRITICAL_COUNT found in task-reviewer output for $TASK_ID"
  echo "Output may be malformed. NOT marking as passed."
  echo "Review the output manually and run /wave-gate again."
  # Don't store anything - leave review_status as null (requires re-review)
  exit 0
fi

# Store findings via helper script
if [[ -n "$FINDINGS" ]]; then
  echo "$FINDINGS" | bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID"
elif [[ "$CRITICAL_COUNT" -eq 0 ]]; then
  # Explicit CRITICAL_COUNT: 0 - safe to mark as passed
  echo "No critical findings for $TASK_ID (CRITICAL_COUNT: 0) - marking as passed"
  bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID" <<< ""
else
  # CRITICAL_COUNT > 0 but no findings parsed - parsing failed
  echo "ERROR: CRITICAL_COUNT: $CRITICAL_COUNT but no findings parsed for $TASK_ID"
  echo "Marking as BLOCKED to be safe. Check output format."
  # Store a placeholder critical finding to block advancement
  echo "CRITICAL: Review output parsing failed - $CRITICAL_COUNT findings not captured" | \
    bash ~/.claude/hooks/helpers/store-review-findings.sh --task "$TASK_ID"
fi

exit 0
