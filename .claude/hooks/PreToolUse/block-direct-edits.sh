#!/bin/bash
# Block Edit/Write from the MAIN agent during loom orchestration
# Subagent Edit/Write is allowed — detected via /tmp/claude-subagents/ flag
#
# WHY: Without this, the orchestrator can bypass phases by editing directly.
# Subagents SHOULD edit — that's their job.
#
# NOTE: Exit code 2 requires stderr output!
# NOTE: Hook input comes via stdin!

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

case "$TOOL_NAME" in
  Edit|Write|MultiEdit)
    # Allow if a subagent is active (SubagentStart sets flag, SubagentStop clears it)
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
    if [[ -n "$SESSION_ID" && -s "/tmp/claude-subagents/${SESSION_ID}.active" ]]; then
      exit 0
    fi

    echo "BLOCKED: Direct edits not allowed during loom orchestration." >&2
    echo "" >&2
    echo "Use Task tool with appropriate agent for implementation:" >&2
    echo "  - code-implementer-agent for production code" >&2
    echo "  - java-test-agent or ts-test-agent for tests" >&2
    echo "  - frontend-agent for UI components" >&2
    echo "" >&2
    echo "This ensures proper phase sequencing and review gates." >&2
    exit 2
    ;;
esac

exit 0
