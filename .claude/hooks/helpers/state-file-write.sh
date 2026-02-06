#!/bin/bash
# Atomic state file writer with chmod-based protection
# Handles: chmod 644 → lock → jq transform → chmod 444 → unlock
#
# State file stays chmod 444 at rest. Subagent Write tool calls
# hit OS-level EACCES. Only hooks use this helper to write.
#
# Usage (jq filter via args):
#   bash state-file-write.sh '.tasks[0].status = "done"'
#   bash state-file-write.sh --arg id "T1" '.tasks |= map(if .id == $id then .status = "done" else . end)'
#
# Usage (jq filter via stdin — for complex filters):
#   echo '.tasks[0].status = "done"' | bash state-file-write.sh --stdin
#
# Usage (raw JSON replacement — skip jq):
#   echo '{"tasks":[]}' | bash state-file-write.sh --replace
#
# Environment:
#   TASK_GRAPH - path to state file (default: .claude/state/active_task_graph.json)
#   Uses resolve-task-graph.sh if SESSION_ID is set and local file missing

set -e

TASK_GRAPH="${TASK_GRAPH:-.claude/state/active_task_graph.json}"

# If task graph doesn't exist locally, try session-scoped resolution
if [[ ! -f "$TASK_GRAPH" && -n "$SESSION_ID" ]]; then
  source ~/.claude/hooks/helpers/resolve-task-graph.sh
  TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || { echo "ERROR: No task graph found" >&2; exit 1; }
fi

[[ ! -f "$TASK_GRAPH" ]] && { echo "ERROR: No task graph at $TASK_GRAPH" >&2; exit 1; }

LOCK_FILE="$(dirname "$TASK_GRAPH")/.task_graph.lock"

# Parse mode
MODE="jq_args"
JQ_FILTER=""
JQ_EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdin) MODE="jq_stdin"; shift ;;
    --replace) MODE="replace"; shift ;;
    --arg|--argjson)
      JQ_EXTRA_ARGS+=("$1" "$2" "$3")
      shift 3
      ;;
    *)
      # First non-flag arg is the jq filter
      if [[ -z "$JQ_FILTER" && "$MODE" == "jq_args" ]]; then
        JQ_FILTER="$1"
      fi
      shift
      ;;
  esac
done

# Read stdin for --stdin/--replace modes
STDIN_DATA=""
if [[ "$MODE" == "jq_stdin" || "$MODE" == "replace" ]]; then
  STDIN_DATA=$(cat)
fi

if [[ "$MODE" == "jq_stdin" ]]; then
  JQ_FILTER="$STDIN_DATA"
fi

if [[ "$MODE" != "replace" && -z "$JQ_FILTER" ]]; then
  echo "ERROR: No jq filter provided" >&2
  exit 1
fi

# Acquire lock (NOT auto — we set our own combined trap below)
source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE"

# chmod 644 to allow writes
chmod 644 "$TASK_GRAPH" 2>/dev/null || true

# Combined cleanup: chmod 444 + release lock (single trap to avoid overwrite)
trap 'chmod 444 "$TASK_GRAPH" 2>/dev/null || true; release_lock "$LOCK_FILE"' EXIT

if [[ "$MODE" == "replace" ]]; then
  # Direct replacement (e.g., populate-task-graph uses this)
  echo "$STDIN_DATA" > "${TASK_GRAPH}.tmp"
  mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"
else
  # jq transformation
  jq "${JQ_EXTRA_ARGS[@]}" "$JQ_FILTER" "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"
fi

# chmod 444 restored by trap on exit
