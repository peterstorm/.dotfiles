#!/bin/bash
# Debug: capture stdin and stderr for inspection
INPUT=$(cat)
echo "---$(date)---" >> /tmp/loom-subagent-stop-debug.log
echo "$INPUT" >> /tmp/loom-subagent-stop-debug.log
echo "$INPUT" | bun ~/.claude/hooks/loom/src/cli.ts subagent-stop dispatch 2>> /tmp/loom-subagent-stop-debug.log
EXIT_CODE=$?
echo "EXIT_CODE=$EXIT_CODE" >> /tmp/loom-subagent-stop-debug.log
exit $EXIT_CODE
