#!/usr/bin/env bash
# Cortex SessionStart wrapper - portable across machines
# Finds plugin dynamically and delegates to load-surface.sh

set -euo pipefail

# Find cortex plugin (could be in cache or installed location)
CORTEX_PLUGIN=$(find ~/.claude/plugins -name "cortex" -type d | grep -E "plugins/(cache/)?cortex" | head -1)

if [[ -z "$CORTEX_PLUGIN" ]]; then
  echo "[cortex-wrapper] ERROR: Cortex plugin not found" >&2
  exit 0  # Never block session
fi

# Find the actual versioned plugin root
PLUGIN_ROOT=$(find "$CORTEX_PLUGIN" -name "hooks" -type d | grep -E "[0-9]+\.[0-9]+\.[0-9]+/hooks$" | head -1 | xargs dirname)

if [[ -z "$PLUGIN_ROOT" ]] || [[ ! -f "$PLUGIN_ROOT/hooks/scripts/load-surface.sh" ]]; then
  echo "[cortex-wrapper] ERROR: load-surface.sh not found in $PLUGIN_ROOT" >&2
  exit 0  # Never block session
fi

# Delegate to actual hook script
exec bash "$PLUGIN_ROOT/hooks/scripts/load-surface.sh" "$@"
