#!/bin/bash
# Advance current_phase when phase agents complete
# Updates state file with phase artifacts
#
# Phases: brainstorm → specify → clarify → architecture → decompose → execute

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

# Get agent type directly from SubagentStop input if not already set
if [[ -z "$AGENT_TYPE" ]]; then
  AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
fi

# Map agent type to phase
detect_completed_phase() {
  local agent="$1"
  case "$agent" in
    brainstorm-agent) echo "brainstorm" ;;
    specify-agent) echo "specify" ;;
    clarify-agent) echo "clarify" ;;
    architecture-agent) echo "architecture" ;;
    *) echo "" ;;
  esac
}

COMPLETED_PHASE=$(detect_completed_phase "$AGENT_TYPE")
[[ -z "$COMPLETED_PHASE" ]] && exit 0  # Not a phase agent

# Resolve task graph
source ~/.claude/hooks/helpers/resolve-task-graph.sh
TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
LOCK_FILE=$(task_graph_lock_file "$TASK_GRAPH")

source ~/.claude/hooks/helpers/lock.sh
acquire_lock "$LOCK_FILE" auto

CURRENT_PHASE=$(jq -r '.current_phase // "init"' "$TASK_GRAPH")

# Determine next phase and artifact
NEXT_PHASE=""
ARTIFACT=""

case "$COMPLETED_PHASE" in
  brainstorm)
    NEXT_PHASE="specify"
    ARTIFACT="completed"
    ;;
  specify)
    # Check if clarify needed (markers > 3)
    SPEC_FILE=$(jq -r '.spec_file // empty' "$TASK_GRAPH")
    if [[ -n "$SPEC_FILE" && -f "$SPEC_FILE" ]]; then
      MARKERS=$(grep -c "NEEDS CLARIFICATION" "$SPEC_FILE" 2>/dev/null || echo 0)
      if [[ "$MARKERS" -gt 3 ]]; then
        NEXT_PHASE="clarify"
      else
        NEXT_PHASE="architecture"
        # Auto-skip clarify if markers ≤ 3
        jq '.skipped_phases = ((.skipped_phases // []) + ["clarify"] | unique)' "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"
      fi
      ARTIFACT="$SPEC_FILE"
    else
      NEXT_PHASE="clarify"
      ARTIFACT="completed"
    fi
    ;;
  clarify)
    NEXT_PHASE="architecture"
    # Artifact is the updated spec file
    SPEC_FILE=$(jq -r '.spec_file // empty' "$TASK_GRAPH")
    ARTIFACT="${SPEC_FILE:-completed}"
    ;;
  architecture)
    NEXT_PHASE="decompose"
    PLAN_FILE=$(jq -r '.plan_file // empty' "$TASK_GRAPH")
    ARTIFACT="${PLAN_FILE:-completed}"
    ;;
esac

[[ -z "$NEXT_PHASE" ]] && exit 0

# Update state
jq --arg phase "$NEXT_PHASE" --arg completed "$COMPLETED_PHASE" --arg artifact "$ARTIFACT" '
  .current_phase = $phase |
  .phase_artifacts[$completed] = $artifact |
  .updated_at = (now | todate)
' "$TASK_GRAPH" > "${TASK_GRAPH}.tmp" && mv "${TASK_GRAPH}.tmp" "$TASK_GRAPH"

echo "Phase advanced: $COMPLETED_PHASE → $NEXT_PHASE"
if [[ "$COMPLETED_PHASE" == "specify" && "$NEXT_PHASE" == "architecture" ]]; then
  echo "  (clarify auto-skipped: markers ≤ 3)"
fi

exit 0
