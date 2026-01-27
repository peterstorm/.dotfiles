#!/bin/bash
# Guard state files from direct modification via Bash tool
# Allows reads (jq, cat) but blocks writes (>, mv, cp, tee, sed -i, perl -i)
# Hooks (SubagentStop etc.) bypass PreToolUse entirely, so they can still write
# Only active when task graph exists

TASK_GRAPH=".claude/state/active_task_graph.json"

[[ ! -f "$TASK_GRAPH" ]] && exit 0

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[[ -z "$COMMAND" ]] && exit 0

# Allow whitelisted helper scripts (they do their own validation)
if echo "$COMMAND" | grep -qE '(complete-wave-gate|mark-tests-passed|store-review-findings)\.sh'; then
  exit 0
fi

STATE_FILES="active_task_graph|review-invocations"

# Only inspect commands that reference state files
if echo "$COMMAND" | grep -qE "$STATE_FILES"; then
  # Block write patterns targeting state files
  if echo "$COMMAND" | grep -qE '(>>?|mv |cp |tee |sed -i|perl -i|dd |sponge |python3? .*(open|write)|node .*(writeFile|fs\.))'; then
    echo "BLOCKED: Write to state file not allowed during task-planner workflow." >&2
    echo "State is managed by SubagentStop hooks and helper scripts only." >&2
    echo "Read access (jq, cat) is allowed." >&2
    exit 2
  fi
fi

exit 0
