#!/usr/bin/env bash
# Contracts for the pinned Singularity action candidate and role-aware workflows.
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-singularity-workflows.sh"
DOWNLOADER="$ROOT/scripts/comfyui/download-minimax-h3-singularity-models.sh"
RUNBOOK="$ROOT/docs/runbooks/comfyui-krea2-minimax-h3-muse-runbook.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

for file in "$MODULE" "$BUILDER" "$DOWNLOADER" "$RUNBOOK"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$BUILDER" "$DOWNLOADER"; do
  [[ -x "$file" ]] || fail "missing executable bit: $file"
  bash -n "$file"
done

contains "$DOWNLOADER" 'SINGULARITY_REV="af671d9214a6e41ab8c2f43e9f871ea56246115f"'
contains "$DOWNLOADER" 'TURBO_REV="3ec17a324ced54151364f24f8b5fb6bf7e26414f"'
contains "$DOWNLOADER" '551915097b8727537a82f3a2c5acec965165ec84e780b3e9a5f28ce867fddf08|34004507622|diffusion_models/minimax_h3_singularity_ref2va_v1.3_int8.safetensors'
contains "$DOWNLOADER" '6a56f41ab4229c9dd845b9501bbd475ee57e112d846cf2e819d534a1ae928c5a|1956193000|loras/minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors'
contains "$DOWNLOADER" 'The Singularity repository'
contains "$DOWNLOADER" 'MINIMAX_H3_ACCEPT_LICENSE'
contains "$DOWNLOADER" 'MINIMAX_H3_AUTHORIZED'
contains "$DOWNLOADER" 'verify_installed'

contains "$BUILDER" '00 MiniMax H3 Singularity v1.3 REF2VA 8-Step - Action Quality.json'
contains "$BUILDER" '01 MiniMax H3 Singularity v1.3 REF2VA 4-Step - Fast Iterate.json'
contains "$BUILDER" '02 MiniMax H3 Official BF16 REF2VA 8-Step - Fixed-Seed A-B Control.json'
contains "$BUILDER" 'minimax_h3_singularity_ref2va_v1.3_int8.safetensors'
contains "$BUILDER" 'minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
contains "$BUILDER" 'qwen3vl_32b_minimax_h3_bf16.safetensors'
contains "$BUILDER" 'Picture 1 — approved complete full-look'
contains "$BUILDER" 'Picture 2 — face and hair detail only'
contains "$BUILDER" 'Picture 3 — hand and grip detail only'
contains "$BUILDER" 'Picture 4 — hero prop only'
contains "$BUILDER" 'one causal physical beat'
contains "$BUILDER" 'fixed_seed=20260919'
contains "$BUILDER" '["simple", 8, 1]'
contains "$BUILDER" '["simple", 4, 1]'
contains "$BUILDER" '"$ref2v_4step" 4 0.5 960 544'
contains "$BUILDER" '"$ref2v_8step" 8 0.98 1344 768'
contains "$BUILDER" '[[12, 3]]'
contains "$BUILDER" 'private local Development candidate'
contains "$BUILDER" 'The transcript reports mild noise at four steps'
contains "$BUILDER" 'only the diffusion checkpoint differs.'
contains "$BUILDER" '[[ $(find "$output_dir" -type f -name '\''*.json'\'' | wc -l) -eq 3 ]]'

if grep -Fqi 'motion_enhancer' "$BUILDER"; then
  fail 'builder stacks the incompatible community motion enhancer'
fi
if grep -Fqi 'LBH' "$BUILDER"; then
  fail 'builder silently adopts the unlicensed LBH latent upscaler'
fi

contains "$MODULE" 'name = "download-minimax-h3-singularity-models";'
contains "$MODULE" '${../../scripts/comfyui/build-minimax-h3-singularity-workflows.sh}'
contains "$MODULE" 'minimax-h3-singularity-v1.3-action-development'
contains "$MODULE" 'for source in ${minimaxH3SingularityWorkflows}/workflows/*.json; do'
contains "$MODULE" 'verify_versioned_workflow_install "$h3_singularity_staging" "$h3_singularity_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$h3_singularity_staging" "$h3_singularity_dir"'
contains "$MODULE" 'downloadMinimaxH3SingularityModels'

contains "$RUNBOOK" 'MiniMax H3 Singularity v1.3 action candidate'
contains "$RUNBOOK" 'A same-seed comparison is'
contains "$RUNBOOK" 'role-separated references'
contains "$RUNBOOK" 'download-minimax-h3-singularity-models'
contains "$RUNBOOK" 'minimax-h3-singularity-v1.3-action-development'

nix-instantiate --parse "$MODULE" >/dev/null
printf 'PASS: Singularity is pinned, legally gated, role-aware, A/B-controlled, and Development-only\n'
