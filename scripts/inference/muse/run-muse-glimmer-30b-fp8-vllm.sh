#!/usr/bin/env bash
# Fixed FP8 entry point; target-only is the qualification baseline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MUSE_VLLM_TARGET=fp8
export MUSE_VLLM_SPECULATION="${MUSE_FP8_SPECULATION:-target-only}"
exec "$SCRIPT_DIR/run-muse-glimmer-30b-vllm.sh" "$@"
