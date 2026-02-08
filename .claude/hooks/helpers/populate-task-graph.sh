#!/bin/bash
# Populate task graph state file with decompose output
# Replaces the subagent approach — runs as hook helper, bypasses guard
#
# Usage:
#   echo "$DECOMPOSE_JSON" | bash populate-task-graph.sh [--issue NUMBER] [--repo OWNER/REPO]
#
# Reads existing state (phase tracking), merges with validated decompose JSON,
# adds github_issue, current_wave:1, initializes wave_gates and executing_tasks.
#
# Expects decompose JSON on stdin with: plan_title, plan_file, spec_file, tasks[]
# Validates schema before merging. Use --fix to auto-correct fixable issues.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_GRAPH="${TASK_GRAPH:-.claude/state/active_task_graph.json}"
[[ ! -f "$TASK_GRAPH" ]] && { echo "ERROR: No task graph at $TASK_GRAPH" >&2; exit 1; }

# Parse args
ISSUE=""
REPO=""
AUTO_FIX=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --fix) AUTO_FIX=true; shift ;;
    *) shift ;;
  esac
done

# Read decompose JSON from stdin
DECOMPOSE_JSON=$(cat)

# Validate it's valid JSON
if ! echo "$DECOMPOSE_JSON" | jq empty 2>/dev/null; then
  echo "ERROR: Invalid JSON on stdin" >&2
  exit 1
fi

# Validate decompose schema (defense-in-depth)
if ! echo "$DECOMPOSE_JSON" | bash "$SCRIPT_DIR/validate-task-graph.sh" -; then
  if $AUTO_FIX; then
    echo "Attempting auto-fix..." >&2
    if FIXED=$(echo "$DECOMPOSE_JSON" | bash "$SCRIPT_DIR/validate-task-graph.sh" --fix -); then
      DECOMPOSE_JSON="$FIXED"
      echo "Auto-fix applied" >&2
    else
      echo "ERROR: Auto-fix could not resolve all issues" >&2
      exit 1
    fi
  else
    echo "Hint: re-run with --fix to auto-correct fixable issues" >&2
    exit 1
  fi
fi

# Validate existing state has correct minimal schema
if ! bash "$SCRIPT_DIR/validate-task-graph.sh" --minimal "$TASK_GRAPH" >/dev/null 2>&1; then
  echo "WARNING: Existing state file has invalid minimal schema — fixing" >&2
  EXISTING=$(bash "$SCRIPT_DIR/validate-task-graph.sh" --minimal --fix "$TASK_GRAPH")
else
  EXISTING=$(cat "$TASK_GRAPH")
fi

# Merge: existing phase fields + decompose tasks + new execution fields
MERGED=$(echo "$EXISTING" | jq \
  --argjson decompose "$DECOMPOSE_JSON" \
  --arg issue "${ISSUE:-}" \
  --arg repo "${REPO:-}" '
  # Preserve existing phase tracking
  . +
  # Add decompose fields
  {
    plan_title: $decompose.plan_title,
    plan_file: ($decompose.plan_file // .plan_file),
    spec_file: ($decompose.spec_file // .spec_file),
    tasks: $decompose.tasks,
    current_wave: 1,
    executing_tasks: [],
    wave_gates: (
      [$decompose.tasks[].wave] | unique | sort |
      map(tostring) | map({(.) : {
        impl_complete: false,
        tests_passed: null,
        reviews_complete: false,
        blocked: false
      }}) | add // {}
    )
  } +
  # Conditionally add github fields
  (if $issue != "" then {github_issue: ($issue | tonumber)} else {} end) +
  (if $repo != "" then {github_repo: $repo} else {} end)
')

# Write via state-file-write for chmod protection
echo "$MERGED" | bash ~/.claude/hooks/helpers/state-file-write.sh --replace

echo "Task graph populated: $(echo "$DECOMPOSE_JSON" | jq '.tasks | length') tasks"
echo "Waves: $(echo "$DECOMPOSE_JSON" | jq '[.tasks[].wave] | unique | sort | map(tostring) | join(", ")')"
