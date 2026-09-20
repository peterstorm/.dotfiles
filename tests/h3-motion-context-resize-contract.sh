#!/usr/bin/env bash
# Static and pure-function contract for the H3 Motion Context Resize workflow.
# shellcheck disable=SC2016 # Assertions intentionally match literal source text.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
DOWNLOADER="$ROOT/scripts/comfyui/download-h3-motion-context-resize-models.sh"
RUNBOOK="$ROOT/docs/runbooks/h3-motion-context-resize-v1.1.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

absent() {
  local file=$1 needle=$2
  if grep -Fq -- "$needle" "$file"; then
    fail "$file must not contain: $needle"
  fi
}

for file in "$MODULE" "$DOWNLOADER" "$RUNBOOK"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$DOWNLOADER" ]] || fail "downloader is not executable"
bash -n "$DOWNLOADER"
nix-instantiate --parse "$MODULE" >/dev/null

# --- Nix module wiring: the new resize source ---
contains "$MODULE" 'h3MotionContextResizeSource = pkgs.fetchFromGitHub'
contains "$MODULE" 'rev = "0b9ffee7f2f6f4203a644b99f8d81ad1a9e3fc7e";'
contains "$MODULE" 'hash = "sha256-T+JDVMcRhJOqsW/CtCZl8/V1UT7RYUt3CQb+/TaZjM0=";'

# The 3D latent upscaler is already pinned as minimaxH3LatentUpscalerNode at
# the latest upstream rev (d7c01b90, which includes the rev the workflow's
# aux_id names); the module must not carry a duplicate pin.
contains "$MODULE" 'minimaxH3LatentUpscalerNode = pkgs.fetchFromGitHub'
contains "$MODULE" 'owner = "LBH-123-AI";'
contains "$MODULE" 'rev = "d7c01b9011f2e8439493f6c02c29995a27df276f";'
absent "$MODULE" 'h3LatentUpscaler3DSource'
absent "$MODULE" 'h3LatentUpscaler3DNode'
absent "$MODULE" 'rev = "6a4b191e8af583b7c097f564690325f91d18c2e2";'

# Node derivation with the args-parsing import contract
contains "$MODULE" 'h3MotionContextResizeNode ='
contains "$MODULE" 'comfyui-h3-motion-context-resize-0b9ffee-tested'
contains "$MODULE" 'if "MiniMaxH3MotionContextResize" not in module.NODE_CLASS_MAPPINGS:'
contains "$MODULE" 'ln -s ${h3MotionContextResizeNode} "$out/ComfyUI-H3MotionContextResize"'
contains "$MODULE" 'ln -s ${minimaxH3LatentUpscalerNode} "$out/Comfyui_Minimax_h3_latent_Upscaler"'

# The upscaler's custom model folder must map through the paths config.
contains "$MODULE" '"latent_upscale_models"'

# Workflow install: versioned dir, staging, loop, verify, idempotent install
contains "$MODULE" 'h3_motion_context_resize_dir="$user_workflows/minimax-h3-motion-context-resize-v1.1"'
contains "$MODULE" 'h3_motion_context_resize_staging="$user_workflows/.minimax-h3-motion-context-resize-v1.1.new"'
contains "$MODULE" 'for source in ${h3MotionContextResizeNode}/example_workflows'
contains "$MODULE" 'install -m 0600 "$source" "$h3_motion_context_resize_staging/$(basename "$source")"'
contains "$MODULE" 'verify_versioned_workflow_install "$h3_motion_context_resize_staging" "$h3_motion_context_resize_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$h3_motion_context_resize_staging" "$h3_motion_context_resize_dir"'
absent "$MODULE" 'mv "$h3_motion_context_resize_staging" "$h3_motion_context_resize_dir"'

# Downloader wiring
contains "$MODULE" 'downloadH3MotionContextResizeModels = pkgs.writeShellApplication'
contains "$MODULE" 'name = "download-h3-motion-context-resize-models"'
contains "$MODULE" 'text = builtins.readFile ../../scripts/comfyui/download-h3-motion-context-resize-models.sh;'
contains "$MODULE" '    downloadH3MotionContextResizeModels'

# The downloader owns model installation; nothing in the module downloads at runtime.
absent "$MODULE" 'download-h3-motion-context-resize-models.sh && curl'

# --- Downloader: checksum-verified atomic profile ---
contains "$DOWNLOADER" 'PROFILE_REV="h3-motion-context-resize-models-v1"'
contains "$DOWNLOADER" '4f57821f5837f32f7142b67d815606dbd7550f194e5c769f7d6c3f83b146a5e6 690592992 LBH-123-AI/Minimax_h3_latent_Upscaler 3f941d5d182014dd5c0a5e16330420ee2d4aa0c6 minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors'
contains "$DOWNLOADER" 'H3_MOTION_CONTEXT_RESIZE_MODELS_READY'
# The retired fp16 file must never be fetched; the BF16 file is the highest quant.
absent "$DOWNLOADER" 'minimax_h3_latent_upscaler_3d_fp16.safetensors'

# --- Runbook documents the installed state and the video ---
contains "$RUNBOOK" 'https://youtu.be/rc332zxjQ_I'
contains "$RUNBOOK" 'minimax-h3-motion-context-resize-v1.1'
contains "$RUNBOOK" 'download-h3-motion-context-resize-models'
contains "$RUNBOOK" 'frame_chunk'
contains "$RUNBOOK" 'bislerp'
contains "$RUNBOOK" 'minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors'

printf 'h3-motion-context-resize contract: OK\n'
