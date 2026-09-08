#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix/JQ source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-derope-turbo-workflows.sh"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-derope-turbo.md"
MODEL_DOWNLOAD="$ROOT/scripts/comfyui/download-minimax-h3-models.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file lacks: $needle"
}

for file in "$MODULE" "$BUILDER" "$RUNBOOK" "$MODEL_DOWNLOAD"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "builder is not executable"
bash -n "$BUILDER"

# The three maintained MAINodes v1.1.3 Turbo sources are checksum-gated.
contains "$BUILDER" "c1f8613eedab77d275e6ed48e00792a1ceb751a27d3dbe0d3c8a05197bd162c5 'REF2VA balanced Turbo workflow'"
contains "$BUILDER" "ed2970f5bea60d1de402a5d821f7cb2a615655d68906952073bb76e1560531a5 'FL2VA fast-iterate Turbo workflow'"
contains "$BUILDER" "5a49a4a8c04925629e1385a4649562b5d5bc6c1819fcf5971f15d1660f3bc858 'FL2VA upscale Turbo workflow'"
contains "$MODULE" '${mainodesSource}/examples/motion_pipeline_ref2va_audioinit.json'
contains "$MODULE" '${mainodesSource}/examples/motion_pipeline_fast_iterate.json'
contains "$MODULE" '${mainodesSource}/examples/motion_pipeline_upscale_derope.json'

# Full-BF16 bases feed pass 1; only the task-matched 4-step adapter feeds pass 2.
for selector in \
  minimax_h3_fl2va_bf16.safetensors \
  minimax_h3_ref2va_bf16.safetensors \
  qwen3vl_32b_minimax_h3_bf16.safetensors \
  minimax_h3_video_vae_fp16.safetensors \
  minimax_h3_audio_vae_fp32.safetensors \
  minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors \
  minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors; do
  contains "$BUILDER" "$selector"
done
contains "$BUILDER" '["linear_quadratic", 12, 1]'
contains "$BUILDER" '["gradient_estimation"]'
contains "$BUILDER" '["beta", 6, 0.5, "faithful detail 0.50 (metric best)"]'
contains "$BUILDER" '.[0] == $base_model_link and .[1] != 303'
contains "$BUILDER" '.[0] == $turbo_model_link and .[1] == 303'
contains "$BUILDER" '([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values])'
contains "$BUILDER" '.id != 300 and .id != 301'
contains "$BUILDER" '([.nodes[] | select(.type == "PathchSageAttentionKJ"'
contains "$BUILDER" 'or .type == "MiniMaxH3MemoryEfficientSageAttentionPatch")] | length) == 0'
contains "$BUILDER" '[[9201, 127, 0, 302, 0, "MODEL"]]'
contains "$BUILDER" 'MiniMaxChunkFeedForward'
contains "$BUILDER" "grep -RqiE 'pruned_int8|nvfp4|int8_convrot|lightx2v|resolve/main|tree/main|ComfyUI-Manager|api[_-]?key|token'"
contains "$BUILDER" '[[ $(find "$output_dir" -type f -name '\''*.json'\'' | wc -l) -eq 3 ]]'
contains "$MODEL_DOWNLOAD" 'c396a9a06f58399e9df9754b18299818d84a2ddd371724ba48fe4a41221437dc 1956192992 loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors'
contains "$MODEL_DOWNLOAD" '5b9ab5ade15d0775676d01a907268a69a1468dc6033b3b0d3ded5502f3ebb84c 1956193000 loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'

for filename in \
  '01 MiniMax H3 De-RoPE Turbo v1.1 - REF2VA Balanced Audio Development.json' \
  '02 MiniMax H3 De-RoPE Turbo v1.1 - FL2VA Fast Iterate Development.json' \
  '03 MiniMax H3 De-RoPE Turbo v1.1 - FL2VA Upscale Development.json'; do
  contains "$BUILDER" "$filename"
done

# The corrected package has its own immutable directory and does not alter full-quality v1.0.
contains "$MODULE" 'pkgs.runCommand "minimax-h3-derope-turbo-v1-1-development-workflows"'
contains "$MODULE" 'h3_derope_turbo_dir="$user_workflows/minimax-h3-derope-turbo-development-v1.1"'
contains "$MODULE" 'for source in ${minimaxH3DeropeTurboWorkflows}/workflows/*.json; do'
contains "$MODULE" 'verify_versioned_workflow_install "$h3_derope_turbo_staging" "$h3_derope_turbo_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$h3_derope_turbo_staging" "$h3_derope_turbo_dir"'
contains "$MODULE" 'h3_derope_dir="$user_workflows/minimax-h3-derope-development-v1.0"'

contains "$RUNBOOK" 'putting a Turbo LoRA into the older 25-step/simple/`res_multistep` graph'
contains "$RUNBOOK" 'Turbo is downstream of pass 1 and cannot decide the initial choreography.'
contains "$RUNBOOK" 'V1.1 removes both SageAttention-dependent nodes'
contains "$RUNBOOK" 'Do not use the v1.0 folder.'
contains "$RUNBOOK" 'Compare against the full-BF16 25+25-step REF2VA graph'
contains "$RUNBOOK" 'Development-only'

nix-instantiate --parse "$MODULE" >/dev/null
printf 'PASS: MiniMax H3 De-RoPE Turbo v1.1 preserves the maintained two-pass recipes, task-matched adapters, executable attention path, and immutable Development deployment\n'
