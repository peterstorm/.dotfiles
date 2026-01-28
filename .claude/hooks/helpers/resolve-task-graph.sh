#!/bin/bash
# Resolve task graph path for cross-repo access
# Priority: session-scoped path (cross-repo) > local path (same repo)
#
# Usage:
#   source ~/.claude/hooks/helpers/resolve-task-graph.sh
#   TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
#   LOCK_FILE=$(task_graph_lock_file "$TASK_GRAPH")

resolve_task_graph() {
  local session_id="$1"
  local local_path=".claude/state/active_task_graph.json"
  local session_file="/tmp/claude-subagents/${session_id}.task_graph"

  # Priority 1: Session-scoped path (enables cross-repo access)
  if [[ -n "$session_id" && -f "$session_file" ]]; then
    local abs_path
    abs_path=$(cat "$session_file")
    if [[ -f "$abs_path" ]]; then
      echo "$abs_path"
      return 0
    fi
  fi

  # Priority 2: Local path (same repo as orchestrator)
  if [[ -f "$local_path" ]]; then
    echo "$local_path"
    return 0
  fi

  # Not found
  return 1
}

# Get lock file path for a task graph
task_graph_lock_file() {
  local task_graph="$1"
  echo "$(dirname "$task_graph")/.task_graph.lock"
}
