#!/bin/bash
exec bun ~/.claude/hooks/loom/src/cli.ts session-start cleanup-stale-subagents
