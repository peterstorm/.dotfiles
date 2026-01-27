#!/bin/bash
# Clean up stale subagent tracking files from previous sessions
# Prevents /tmp/claude-subagents/ accumulation across sessions

if [[ -d /tmp/claude-subagents ]]; then
  rm -rf /tmp/claude-subagents/*
fi

exit 0
