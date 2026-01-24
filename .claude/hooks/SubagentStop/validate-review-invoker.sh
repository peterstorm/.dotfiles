#!/bin/bash
# Validates that review-invoker agent called /review-pr skill
# Checks for breadcrumb in .claude/state/review-invocations.json

set -e

INPUT=$(cat)

# Extract agent type from input
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# Only validate review-invoker agents
if [ "$AGENT_TYPE" != "review-invoker" ]; then
  exit 0
fi

# Extract task ID from agent output (look for --task T\d+)
AGENT_OUTPUT=$(echo "$INPUT" | jq -r '.agent_output // empty')
TASK_ID=$(echo "$AGENT_OUTPUT" | grep -oE '\-\-task T[0-9]+' | head -1 | sed 's/--task //')

if [ -z "$TASK_ID" ]; then
  # Try to extract from the prompt
  TASK_ID=$(echo "$INPUT" | jq -r '.agent_prompt // empty' | grep -oE '\-\-task T[0-9]+' | head -1 | sed 's/--task //')
fi

if [ -z "$TASK_ID" ]; then
  echo "Warning: Could not extract task ID from review-invoker output" >&2
  exit 0  # Don't block if we can't determine task ID
fi

# Check for breadcrumb
INVOCATIONS=".claude/state/review-invocations.json"

if [ ! -f "$INVOCATIONS" ]; then
  echo "BLOCKED: review-invoker did not invoke /review-pr (no breadcrumb file)" >&2
  echo "Task $TASK_ID must invoke: Skill(skill: 'review-pr', args: '--files ... --task $TASK_ID')" >&2
  exit 2
fi

# Check if this task's breadcrumb exists
BREADCRUMB=$(jq -r --arg task "$TASK_ID" '.[$task] // empty' "$INVOCATIONS")

if [ -z "$BREADCRUMB" ]; then
  echo "BLOCKED: review-invoker did not invoke /review-pr for task $TASK_ID" >&2
  echo "Breadcrumb missing. Agent must call: Skill(skill: 'review-pr', args: '--task $TASK_ID ...')" >&2
  exit 2
fi

echo "✓ review-invoker correctly invoked /review-pr for task $TASK_ID" >&2
exit 0
