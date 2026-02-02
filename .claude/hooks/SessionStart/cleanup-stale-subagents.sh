#!/bin/bash
# Clean up stale subagent tracking files from previous sessions
# Prevents /tmp/claude-subagents/ accumulation across sessions
#
# IMPORTANT: Only deletes files older than 60 minutes to avoid breaking
# parallel Claude sessions. Two sessions running simultaneously would
# otherwise destroy each other's agent type tracking files.

if [[ -d /tmp/claude-subagents ]]; then
  # Delete files older than 60 minutes only, preserving active sessions
  find /tmp/claude-subagents -type f -mmin +60 -delete 2>/dev/null || true
fi

exit 0
