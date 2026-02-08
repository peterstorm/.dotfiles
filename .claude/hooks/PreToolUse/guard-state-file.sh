#!/bin/bash
exec bun ~/.claude/hooks/loom/src/cli.ts pre-tool-use guard-state-file
