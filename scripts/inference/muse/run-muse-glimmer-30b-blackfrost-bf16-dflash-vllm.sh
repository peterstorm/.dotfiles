#!/usr/bin/env bash
# Fixed Blackfrost BF16 + official Muse DFlash entry point.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MUSE_VLLM_TARGET=blackfrost-bf16
export MUSE_VLLM_SPECULATION=dflash
exec "$SCRIPT_DIR/run-muse-glimmer-30b-vllm.sh" "$@"
