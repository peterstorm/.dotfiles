#!/usr/bin/env bash
# Static contract for the HJteqahyEKM MiniMax H3 Dual Sampling profile.
# shellcheck disable=SC2016 # Assertions intentionally match literal source text.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-dual-sampling-workflows.sh"
DOWNLOADER="$ROOT/scripts/comfyui/download-minimax-h3-dual-sampling-models.sh"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-dual-sampling.md"

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

for file in "$MODULE" "$BUILDER" "$DOWNLOADER" "$RUNBOOK"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "builder is not executable"
[[ -x "$DOWNLOADER" ]] || fail "downloader is not executable"
bash -n "$BUILDER"
bash -n "$DOWNLOADER"
nix-instantiate --parse "$MODULE" >/dev/null

# Workflow package and immutable install.
contains "$MODULE" 'minimaxH3DualSamplingWorkflows ='
contains "$MODULE" 'build-minimax-h3-dual-sampling-workflows.sh'
contains "$MODULE" 'h3_dual_dir="$user_workflows/minimax-h3-dual-sampling-v1.0"'
contains "$MODULE" 'verify_versioned_workflow_install "$h3_dual_staging" "$h3_dual_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$h3_dual_staging" "$h3_dual_dir"'
contains "$MODULE" 'downloadMinimaxH3DualSamplingModels = pkgs.writeShellApplication'
contains "$MODULE" 'downloadMinimaxH3DualSamplingModels'

# Complete three-pass topology and maximum-quality selectors.
contains "$BUILDER" "bf16_model='minimax_h3_ref2va_bf16.safetensors'"
contains "$BUILDER" "singularity_model='minimax_h3_singularity_ref2va_v1.3_int8.safetensors'"
contains "$BUILDER" "text_encoder='qwen3vl_32b_minimax_h3_bf16.safetensors'"
contains "$BUILDER" "upscaler='minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors'"
contains "$BUILDER" '"id":147,"type":"SplitSigmas"'
contains "$BUILDER" '"widgets_values":[0]'
contains "$BUILDER" '"id":148,"type":"SplitSigmas"'
contains "$BUILDER" '"widgets_values":[2]'
contains "$BUILDER" '"id":153,"type":"DisableNoise"'
contains "$BUILDER" '| .id = 154'
contains "$BUILDER" '| .id = 156'
contains "$BUILDER" '"scale by multiplier",1.25,32,true,true,"cuda","bf16"'
contains "$BUILDER" '[$turbo,1], [$lms,0.5], [$realism,1]'
contains "$BUILDER" 'and ([.nodes[] | select(.type == "SamplerCustomAdvanced")] | length) == 3'
contains "$BUILDER" 'and all(.links[]; . as $edge'
absent "$BUILDER" "text_encoder='qwen3vl_32b_minimax_h3_int8_convrot.safetensors'"
absent "$BUILDER" "upscaler='minimax_h3_latent_upscaler_3d_fp16.safetensors'"

# LMS model identity is immutable and atomically installed.
contains "$DOWNLOADER" 'REV="0ff489e781c274d17b2e3a30cd6f9a8d40ca49ff"'
contains "$DOWNLOADER" 'SHA256="16f3195bc6bffa431c0598dc2031e520ba058b4fcbc9f104db9e3fdfdeacf60c"'
contains "$DOWNLOADER" 'SIZE="1239664536"'
contains "$DOWNLOADER" 'mv -f "$DESTINATION.new" "$DESTINATION"'
contains "$DOWNLOADER" 'MINIMAX_H3_DUAL_SAMPLING_LMS_READY'

# Runbook carries the source boundary, quant policy, and no-coexistence rule.
contains "$RUNBOOK" 'https://youtu.be/HJteqahyEKM'
contains "$RUNBOOK" 'The Gumroad JSON is checkout-gated'
contains "$RUNBOOK" 'official unpruned BF16 Ref2VA checkpoint'
contains "$RUNBOOK" 'no BF16 checkpoint'
contains "$RUNBOOK" 'container is not stopped or restarted.'

printf 'minimax-h3 dual-sampling contract: OK\n'
