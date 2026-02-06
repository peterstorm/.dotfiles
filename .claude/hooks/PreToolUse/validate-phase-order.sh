#!/bin/bash
# Enforce phase ordering: brainstorm → specify → clarify → architecture → decompose → execute
# Blocks agent spawns if prerequisite phases not complete
#
# Phase transitions:
#   null/init → brainstorm (default) OR specify (--skip-brainstorm)
#   brainstorm → specify
#   specify → clarify (if markers > 3) OR architecture (if markers ≤ 3 or --skip-clarify)
#   clarify → architecture
#   architecture → decompose
#   decompose → execute
#
# NOTE: Exit code 2 requires stderr output!
# NOTE: Hook input comes via stdin!

source ~/.claude/hooks/helpers/loom-config.sh

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Task" ]] && exit 0

PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty')
SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# Allow utility agents through — orchestrator needs these for research
case "$SUBAGENT_TYPE" in
  Explore|Plan|haiku) exit 0 ;;
esac

# Map agent to phase
detect_phase() {
  local agent="$1"
  local prompt="$2"

  case "$agent" in
    brainstorm-agent) echo "brainstorm" ;;
    specify-agent) echo "specify" ;;
    clarify-agent) echo "clarify" ;;
    architecture-agent) echo "architecture" ;;
    decompose-agent) echo "decompose" ;;
    code-implementer-agent|java-test-agent|ts-test-agent|frontend-agent|security-agent|k8s-agent|keycloak-agent|dotfiles-agent|general-purpose|spec-check-invoker|review-invoker) echo "execute" ;;
    *)
      # Check prompt for phase indicators
      if echo "$prompt" | grep -qiE 'brainstorm|explore.*intent|refine.*idea'; then
        echo "brainstorm"
      elif echo "$prompt" | grep -qiE 'specify|specification|requirements|spec\.md'; then
        echo "specify"
      elif echo "$prompt" | grep -qiE 'clarify|resolve.*markers|NEEDS CLARIFICATION'; then
        echo "clarify"
      elif echo "$prompt" | grep -qiE 'architecture|design|plan\.md'; then
        echo "architecture"
      else
        echo "unknown"
      fi
      ;;
  esac
}

TARGET_PHASE=$(detect_phase "$SUBAGENT_TYPE" "$PROMPT")
# Block unrecognized agents during orchestration - prevents bypass via empty subagent_type
if [[ "$TARGET_PHASE" == "unknown" ]]; then
  echo "BLOCKED: Unrecognized agent type during loom orchestration." >&2
  echo "" >&2
  echo "Agent: $SUBAGENT_TYPE" >&2
  echo "" >&2
  echo "Use a recognized phase agent:" >&2
  echo "  brainstorm-agent, specify-agent, clarify-agent, architecture-agent," >&2
  echo "  code-implementer-agent, java-test-agent, ts-test-agent, etc." >&2
  exit 2
fi

CURRENT_PHASE=$(jq -r '.current_phase // "init"' "$TASK_GRAPH")
SKIPPED=$(jq -r '.skipped_phases // [] | join(",")' "$TASK_GRAPH")

# Check valid transitions
is_valid_transition() {
  local from="$1"
  local to="$2"

  case "$from:$to" in
    init:brainstorm|init:specify) return 0 ;;
    brainstorm:specify) return 0 ;;
    specify:clarify|specify:architecture) return 0 ;;
    clarify:architecture) return 0 ;;
    architecture:decompose) return 0 ;;
    decompose:execute) return 0 ;;
    execute:execute) return 0 ;;  # Multiple impl tasks OK
    *) return 1 ;;
  esac
}

# Check artifact requirements
check_artifacts() {
  local phase="$1"

  case "$phase" in
    specify)
      # Brainstorm must be complete (or skipped)
      if [[ "$CURRENT_PHASE" == "init" ]] && ! echo "$SKIPPED" | grep -q "brainstorm"; then
        echo "brainstorm"
        return 1
      fi
      ;;
    clarify)
      # Spec file must exist
      SPEC=$(jq -r '.phase_artifacts.specify // empty' "$TASK_GRAPH")
      if [[ -z "$SPEC" || ! -f "$SPEC" ]]; then
        echo "specify (no spec.md found)"
        return 1
      fi
      ;;
    architecture)
      # Spec must exist + markers resolved (or clarify skipped)
      SPEC=$(jq -r '.phase_artifacts.specify // .spec_file // empty' "$TASK_GRAPH")
      if [[ -z "$SPEC" || ! -f "$SPEC" ]]; then
        echo "specify (no spec.md found)"
        return 1
      fi
      if ! echo "$SKIPPED" | grep -q "clarify"; then
        MARKERS=$(grep -c "NEEDS CLARIFICATION" "$SPEC" 2>/dev/null || echo 0)
        if [[ "$MARKERS" -gt "$CLARIFY_THRESHOLD" ]]; then
          echo "clarify ($MARKERS markers > $CLARIFY_THRESHOLD)"
          return 1
        fi
      fi
      ;;
    decompose|execute)
      # Plan must exist
      PLAN=$(jq -r '.phase_artifacts.architecture // .plan_file // empty' "$TASK_GRAPH")
      if [[ -z "$PLAN" || ! -f "$PLAN" ]]; then
        echo "architecture (no plan.md found)"
        return 1
      fi
      ;;
  esac
  return 0
}

# Validate transition
if ! is_valid_transition "$CURRENT_PHASE" "$TARGET_PHASE"; then
  echo "BLOCKED: Invalid phase transition: $CURRENT_PHASE → $TARGET_PHASE" >&2
  echo "" >&2
  echo "Expected flow: brainstorm → specify → clarify → architecture → decompose → execute" >&2
  echo "Current phase: $CURRENT_PHASE" >&2
  echo "" >&2
  case "$CURRENT_PHASE" in
    init) echo "Next: Run brainstorm-agent (or --skip-brainstorm)" >&2 ;;
    brainstorm) echo "Next: Run specify-agent" >&2 ;;
    specify) echo "Next: Run clarify-agent or architecture-agent" >&2 ;;
    clarify) echo "Next: Run architecture-agent" >&2 ;;
    architecture) echo "Next: Decompose tasks" >&2 ;;
  esac
  exit 2
fi

# Check artifact requirements
MISSING=$(check_artifacts "$TARGET_PHASE")
if [[ $? -ne 0 ]]; then
  echo "BLOCKED: Missing prerequisite for $TARGET_PHASE phase" >&2
  echo "" >&2
  echo "Required: $MISSING" >&2
  echo "" >&2
  echo "Complete the prerequisite phase first, or use --skip-X flag." >&2
  exit 2
fi

exit 0
