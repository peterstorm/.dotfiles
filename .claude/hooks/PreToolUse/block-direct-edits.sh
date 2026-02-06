#!/bin/bash
# Block Edit/Write during loom orchestration
# Forces use of Task tool with appropriate agents for implementation
#
# WHY THIS IS CRITICAL:
# Without this hook, Claude can bypass the entire orchestration by editing
# files directly, skipping phases like brainstorm/specify/architecture.
# Subagents bypass PreToolUse hooks, so they CAN edit - this is intentional.
#
# NOTE: Exit code 2 requires stderr output!
# NOTE: Hook input comes via stdin!

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

case "$TOOL_NAME" in
  Edit|Write|MultiEdit)
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
