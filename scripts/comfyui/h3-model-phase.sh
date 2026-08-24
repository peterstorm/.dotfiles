#!/usr/bin/env bash
# Compatibility adapter for the canonical creative-model-phase command.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE="${CREATIVE_MODEL_PHASE_BIN:-$SCRIPT_DIR/creative-model-phase.sh}"

case "${1:-}" in
  prepare)
    case "${2:-}" in
      fl2va) exec "$PHASE" prepare h3-fl2va ;;
      ref2va) exec "$PHASE" prepare h3-ref2va ;;
      *) echo 'error: family must be fl2va or ref2va' >&2; exit 2 ;;
    esac
    ;;
  status | release | -h | --help | help)
    exec "$PHASE" "$@"
    ;;
  *)
    cat >&2 <<'EOF'
Usage:
  h3-model-phase status
  h3-model-phase prepare <fl2va|ref2va>
  h3-model-phase release
EOF
    exit 2
    ;;
esac
