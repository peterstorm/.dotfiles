#!/bin/bash
# Advance current_phase when phase agents complete
# Updates state file with phase artifacts
#
# Phases: brainstorm → specify → clarify → architecture → decompose → execute

source ~/.claude/hooks/helpers/loom-config.sh
source ~/.claude/hooks/helpers/parse-phase-artifacts.sh

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')

# Map agent type to phase
detect_completed_phase() {
  local agent="$1"
  case "$agent" in
    brainstorm-agent) echo "brainstorm" ;;
    specify-agent) echo "specify" ;;
    clarify-agent) echo "clarify" ;;
    architecture-agent) echo "architecture" ;;
    decompose-agent) echo "decompose" ;;
    *) echo "" ;;
  esac
}

COMPLETED_PHASE=$(detect_completed_phase "$AGENT_TYPE")
[[ -z "$COMPLETED_PHASE" ]] && exit 0  # Not a phase agent

# Resolve task graph
source ~/.claude/hooks/helpers/resolve-task-graph.sh
TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
export TASK_GRAPH
export SESSION_ID

CURRENT_PHASE=$(jq -r '.current_phase // "init"' "$TASK_GRAPH")

# Brainstorm: only advance if agent wrote brainstorm.md to .claude/specs/
# File-based check — same pattern as specify (spec.md) and architecture (plan.md)
if [[ "$COMPLETED_PHASE" == "brainstorm" ]]; then
  BRAINSTORM_FILE=$(find .claude/specs -name "brainstorm.md" -type f 2>/dev/null | head -1)
  if [[ -z "$BRAINSTORM_FILE" ]]; then
    echo "Brainstorm agent returned without writing brainstorm.md — not advancing"
    exit 0
  fi
fi

# ===== Extract and store phase artifacts from transcript =====
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
  ARTIFACTS=$(parse_phase_artifacts "$TRANSCRIPT_PATH")
  EXTRACTED_SPEC=$(echo "$ARTIFACTS" | jq -r '.spec_file // empty')
  EXTRACTED_PLAN=$(echo "$ARTIFACTS" | jq -r '.plan_file // empty')

  # Store spec_file if extracted and valid
  if [[ -n "$EXTRACTED_SPEC" && -f "$EXTRACTED_SPEC" && "$EXTRACTED_SPEC" == *".claude/specs/"* ]]; then
    CURRENT_SPEC=$(jq -r '.spec_file // empty' "$TASK_GRAPH")
    if [[ -z "$CURRENT_SPEC" || "$CURRENT_SPEC" == "null" ]]; then
      bash ~/.claude/hooks/helpers/state-file-write.sh \
        --arg spec "$EXTRACTED_SPEC" \
        '.spec_file = $spec'
      echo "Captured spec_file: $EXTRACTED_SPEC"
    fi
  fi

  # Store plan_file if extracted and valid
  if [[ -n "$EXTRACTED_PLAN" && -f "$EXTRACTED_PLAN" && "$EXTRACTED_PLAN" == *".claude/plans/"* ]]; then
    CURRENT_PLAN=$(jq -r '.plan_file // empty' "$TASK_GRAPH")
    if [[ -z "$CURRENT_PLAN" || "$CURRENT_PLAN" == "null" ]]; then
      bash ~/.claude/hooks/helpers/state-file-write.sh \
        --arg plan "$EXTRACTED_PLAN" \
        '.plan_file = $plan'
      echo "Captured plan_file: $EXTRACTED_PLAN"
    fi
  fi

  # Refresh state after potential writes
  TASK_GRAPH=$(resolve_task_graph "$SESSION_ID") || exit 0
fi

# Determine next phase and artifact
NEXT_PHASE=""
ARTIFACT=""

case "$COMPLETED_PHASE" in
  brainstorm)
    NEXT_PHASE="specify"
    BRAINSTORM_FILE=$(find .claude/specs -name "brainstorm.md" -type f 2>/dev/null | head -1)
    if [[ -z "$BRAINSTORM_FILE" || ! -f "$BRAINSTORM_FILE" ]]; then
      echo "ERROR: brainstorm phase requires brainstorm.md in .claude/specs/ — not advancing" >&2
      exit 0
    fi
    ARTIFACT="$BRAINSTORM_FILE"
    ;;
  specify)
    # spec_file must be in .claude/specs/ — reject pre-populated non-spec paths
    SPEC_FILE=$(jq -r '.spec_file // empty' "$TASK_GRAPH")
    if [[ -z "$SPEC_FILE" || ! -f "$SPEC_FILE" || "$SPEC_FILE" != *".claude/specs/"* ]]; then
      echo "ERROR: specify phase requires spec_file in .claude/specs/ — not advancing" >&2
      exit 0
    fi
    # Check if clarify needed (markers > CLARIFY_THRESHOLD)
    MARKERS=$(grep -c "NEEDS CLARIFICATION" "$SPEC_FILE" 2>/dev/null || true)
    if [[ "$MARKERS" -gt "$CLARIFY_THRESHOLD" ]]; then
      NEXT_PHASE="clarify"
    else
      NEXT_PHASE="architecture"
      # Auto-skip clarify if markers ≤ CLARIFY_THRESHOLD
      bash ~/.claude/hooks/helpers/state-file-write.sh '.skipped_phases = ((.skipped_phases // []) + ["clarify"] | unique)'
    fi
    ARTIFACT="$SPEC_FILE"
    ;;
  clarify)
    SPEC_FILE=$(jq -r '.spec_file // empty' "$TASK_GRAPH")
    if [[ -z "$SPEC_FILE" || ! -f "$SPEC_FILE" ]]; then
      echo "ERROR: clarify phase requires spec_file on disk — not advancing" >&2
      exit 0
    fi
    # Only advance if markers actually resolved (≤ threshold)
    MARKERS=$(grep -c "NEEDS CLARIFICATION" "$SPEC_FILE" 2>/dev/null || true)
    MARKERS=${MARKERS:-0}
    if [[ "$MARKERS" -gt "$CLARIFY_THRESHOLD" ]]; then
      echo "Clarify agent returned but $MARKERS markers remain (> $CLARIFY_THRESHOLD) — not advancing"
      exit 0
    fi
    NEXT_PHASE="architecture"
    ARTIFACT="$SPEC_FILE"
    ;;
  architecture)
    NEXT_PHASE="decompose"
    PLAN_FILE=$(jq -r '.plan_file // empty' "$TASK_GRAPH")
    if [[ -z "$PLAN_FILE" || "$PLAN_FILE" == "null" || ! -f "$PLAN_FILE" ]]; then
      echo "ERROR: architecture phase requires plan_file on disk — not advancing" >&2
      exit 0
    fi
    ARTIFACT="$PLAN_FILE"
    ;;
  decompose)
    NEXT_PHASE="execute"
    ARTIFACT="completed"
    ;;
esac

[[ -z "$NEXT_PHASE" ]] && exit 0

# Defense-in-depth: validate artifact matches phase contract
case "$COMPLETED_PHASE" in
  brainstorm|specify)
    [[ ! -f "$ARTIFACT" ]] && { echo "BUG: $COMPLETED_PHASE artifact not a file" >&2; exit 0; }
    [[ "$ARTIFACT" != *".claude/specs/"* ]] && { echo "BUG: $COMPLETED_PHASE artifact not in .claude/specs/" >&2; exit 0; }
    ;;
  clarify)
    [[ ! -f "$ARTIFACT" ]] && { echo "BUG: clarify artifact not a file" >&2; exit 0; }
    ;;
  architecture)
    [[ ! -f "$ARTIFACT" ]] && { echo "BUG: architecture artifact not a file" >&2; exit 0; }
    [[ "$ARTIFACT" != *".claude/plans/"* ]] && { echo "BUG: architecture artifact not in .claude/plans/" >&2; exit 0; }
    ;;
esac

# Update state
bash ~/.claude/hooks/helpers/state-file-write.sh \
  --arg phase "$NEXT_PHASE" \
  --arg completed "$COMPLETED_PHASE" \
  --arg artifact "$ARTIFACT" \
  '.current_phase = $phase | .phase_artifacts[$completed] = $artifact | .updated_at = (now | todate)'

echo "Phase advanced: $COMPLETED_PHASE → $NEXT_PHASE"
if [[ "$COMPLETED_PHASE" == "specify" && "$NEXT_PHASE" == "architecture" ]]; then
  echo "  (clarify auto-skipped: markers ≤ $CLARIFY_THRESHOLD)"
fi

exit 0
