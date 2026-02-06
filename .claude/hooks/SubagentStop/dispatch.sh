#!/bin/bash
# SubagentStop dispatcher — reads stdin once, routes to relevant hooks only
#
# Problem: All 6 SubagentStop hooks fire for every agent completion.
# Each independently parses JSON stdin, resolves task graph, etc.
# Most exit immediately after discovering they're not relevant.
#
# Solution: Single dispatcher reads stdin once, extracts agent_type,
# then only calls the hooks that care about this agent type.
#
# Agent → Hook routing:
#   Phase agents (brainstorm/specify/clarify/architecture/decompose)
#     → advance-phase.sh + cleanup
#   Impl agents (code-implementer/java-test/ts-test/frontend/security/k8s/keycloak/dotfiles/general-purpose)
#     → update-task-status.sh + cleanup
#   review-invoker
#     → store-reviewer-findings.sh + validate-review-invoker.sh + cleanup
#   spec-check-invoker
#     → store-spec-check-findings.sh + cleanup
#   Other
#     → cleanup only

HOOK_DIR="$(dirname "$0")"

# Read stdin once, store for re-piping
INPUT=$(cat)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# cleanup-subagent-flag.sh always runs (agent-agnostic)
echo "$INPUT" | bash "$HOOK_DIR/cleanup-subagent-flag.sh"

# No task graph → no orchestration hooks needed
TASK_GRAPH=".claude/state/active_task_graph.json"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [[ -n "$SESSION_ID" ]]; then
  SESSION_PATH="/tmp/claude-subagents/${SESSION_ID}.task_graph"
  if [[ -f "$SESSION_PATH" ]]; then
    RESOLVED=$(cat "$SESSION_PATH")
    [[ -f "$RESOLVED" ]] && TASK_GRAPH="$RESOLVED"
  fi
fi
[[ ! -f "$TASK_GRAPH" ]] && exit 0

# Route to relevant hooks by agent type
case "$AGENT_TYPE" in
  # Phase agents → advance phase tracking
  brainstorm-agent|specify-agent|clarify-agent|architecture-agent|decompose-agent)
    echo "$INPUT" | bash "$HOOK_DIR/advance-phase.sh"
    ;;

  # Impl agents → update task status (tests + new-test verification)
  code-implementer-agent|java-test-agent|ts-test-agent|frontend-agent|\
  security-agent|k8s-agent|keycloak-agent|dotfiles-agent|general-purpose)
    echo "$INPUT" | bash "$HOOK_DIR/update-task-status.sh"
    ;;

  # Review invoker → store findings + validate skill invocation
  review-invoker)
    echo "$INPUT" | bash "$HOOK_DIR/store-reviewer-findings.sh"
    echo "$INPUT" | bash "$HOOK_DIR/validate-review-invoker.sh"
    ;;

  # Spec-check invoker → store spec-check findings
  spec-check-invoker)
    echo "$INPUT" | bash "$HOOK_DIR/store-spec-check-findings.sh"
    ;;

  # Unknown agent type → no orchestration hooks (cleanup already ran)
  *)
    ;;
esac

exit 0
