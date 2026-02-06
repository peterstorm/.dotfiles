#!/bin/bash
# Validate that Task tool prompts have no unsubstituted template variables
# Blocks Task spawns containing {variable} patterns that should have been substituted
#
# Active only during loom orchestration (task graph exists)
# Exit 0 = allow, Exit 2 = block (stderr message required)

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Read hook input from stdin
INPUT=$(cat)

# Only check Task tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Task" ]] && exit 0

# Extract prompt from Task tool input
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty')
[[ -z "$PROMPT" ]] && exit 0

# Check for unsubstituted template variables
# Pattern: {word} where word is alphanumeric + underscore
# Exclude: JSON-like patterns {" or }, shell expansions ${, regex {n,m}

# First, remove shell ${var} expansions to avoid false positives
PROMPT_CLEANED=$(echo "$PROMPT" | sed 's/\${[^}]*}//g')

UNSUBSTITUTED=$(echo "$PROMPT_CLEANED" | grep -oE '\{[a-zA-Z_][a-zA-Z0-9_]*\}' | sort -u)

if [[ -n "$UNSUBSTITUTED" ]]; then
  # Filter out common false positives
  REAL_ISSUES=""
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    case "$var" in
      # JSON/object syntax (unlikely in prompts but skip)
      '{type}'|'{id}'|'{name}') ;;
      # Common template variables that ARE problems
      *)
        REAL_ISSUES="${REAL_ISSUES}${var} "
        ;;
    esac
  done <<< "$UNSUBSTITUTED"

  if [[ -n "$REAL_ISSUES" ]]; then
    echo "BLOCKED: Task prompt contains unsubstituted template variables:" >&2
    echo "  $REAL_ISSUES" >&2
    echo "" >&2
    echo "These should have been substituted before spawning:" >&2
    for var in $REAL_ISSUES; do
      echo "  - $var" >&2
    done
    echo "" >&2
    echo "Check the /loom skill template substitution logic." >&2
    exit 2
  fi
fi

exit 0
