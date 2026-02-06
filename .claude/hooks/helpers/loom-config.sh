#!/bin/bash
# Shared constants for loom hooks.
# Skills reference these values — update docs if changed.
#
# Referenced by:
#   hooks/PreToolUse/validate-phase-order.sh
#   hooks/SubagentStop/advance-phase.sh
#   skills/loom/SKILL.md
#   skills/specify/SKILL.md
#   skills/clarify/SKILL.md
#   tests/test-loom.sh

CLARIFY_THRESHOLD=3  # markers above this trigger mandatory clarify phase
