#!/usr/bin/env bash
# Extract and Generate Hook Shim (Stop Hook)
#
# Satisfies:
# - FR-119: Receives Stop hook input as JSON stdin (session_id, transcript_path, cwd)
# - FR-022: Generate triggers after extraction completes
#
# Architecture:
# Thin shell orchestrator - reads stdin JSON, pipes to extract CLI, then calls generate.
# ALL errors caught and logged, NEVER block session (exit 0 always).
#
# Usage (invoked by Stop hook):
# echo '{"session_id":"...","transcript_path":"...","cwd":"..."}' | ./extract-and-generate.sh

set -euo pipefail

# Resolve plugin root (this script is in hooks/scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLI_PATH="${PLUGIN_ROOT}/engine/src/cli.ts"

# Logging helper
log_error() {
  echo "[cortex-hook] ERROR: $*" >&2
}

log_info() {
  echo "[cortex-hook] INFO: $*" >&2
}

# Main execution wrapped in error handler
main() {
  # Read stdin JSON (Stop hook input)
  local stdin_json
  stdin_json=$(cat)

  if [[ -z "$stdin_json" ]]; then
    log_error "No stdin input (expected JSON with session_id, transcript_path, cwd)"
    return 0  # Never block session
  fi

  log_info "Received Stop hook input, starting extraction..."

  # Parse cwd from stdin JSON for generate command
  local cwd
  cwd=$(echo "$stdin_json" | bun -e "console.log(JSON.parse(require('fs').readFileSync(0, 'utf8')).cwd)" 2>/dev/null || echo "")

  # Step 1: Extract (pipe stdin JSON to CLI)
  if ! echo "$stdin_json" | bun "$CLI_PATH" extract 2>&1 | tee /tmp/cortex-extract.log; then
    log_error "Extract failed (see /tmp/cortex-extract.log)"
    # Continue to generate anyway - may have partial results
  fi

  # Step 2: Generate push surface (if we got cwd)
  if [[ -n "$cwd" ]]; then
    log_info "Generating push surface for cwd: $cwd"
    if ! bun "$CLI_PATH" generate "$cwd" 2>&1 | tee /tmp/cortex-generate.log; then
      log_error "Generate failed (see /tmp/cortex-generate.log)"
    fi
  else
    log_error "Could not parse cwd from stdin JSON, skipping generate"
  fi

  log_info "Stop hook complete"
}

# Execute main with full error handling - NEVER let errors propagate
if ! main "$@"; then
  log_error "Unhandled error in Stop hook"
fi

# Always exit 0 - never block session
exit 0
