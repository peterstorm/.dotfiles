#!/usr/bin/env bash
# Cortex SessionEnd wrapper - portable across machines
# Finds plugin dynamically and delegates to extract-and-generate.sh

set -euo pipefail

# Guard: prevent recursive hook storm (belt-and-suspenders with extract-and-generate.sh)
if [[ "${CORTEX_EXTRACTING:-}" == "1" ]]; then
  exit 0
fi

# Find cortex plugin (could be in cache or installed location)
CORTEX_PLUGIN=$(find ~/.claude/plugins -name "cortex" -type d | grep -E "plugins/(cache/)?cortex" | head -1)

if [[ -z "$CORTEX_PLUGIN" ]]; then
  echo "[cortex-wrapper] ERROR: Cortex plugin not found" >&2
  exit 0  # Never block session
fi

# Find the actual versioned plugin root
PLUGIN_ROOT=$(find "$CORTEX_PLUGIN" -name "hooks" -type d | grep -E "[0-9]+\.[0-9]+\.[0-9]+/hooks$" | head -1 | xargs dirname)

if [[ -z "$PLUGIN_ROOT" ]] || [[ ! -f "$PLUGIN_ROOT/hooks/scripts/extract-and-generate.sh" ]]; then
  echo "[cortex-wrapper] ERROR: extract-and-generate.sh not found in $PLUGIN_ROOT" >&2
  exit 0  # Never block session
fi

# Delegate to actual hook script
exec bash "$PLUGIN_ROOT/hooks/scripts/extract-and-generate.sh" "$@"
