#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix/JQ source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-derope-workflows.sh"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-derope.md"
RESEARCH="$ROOT/docs/research/2026-09-08-minimax-h3-derope-video-research.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file lacks: $needle"
}

for file in "$MODULE" "$BUILDER" "$RUNBOOK" "$RESEARCH"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "builder is not executable"
bash -n "$BUILDER"

# Public GPL source and the exact v1.1.3 release contemporary with the video.
contains "$MODULE" 'owner = "matlowai";'
contains "$MODULE" 'repo = "ComfyUI-MAINodes";'
contains "$MODULE" 'rev = "f4868b4a08e8a504ce86db54a17961d399ffa2bc";'
contains "$MODULE" 'hash = "sha256-+J7FmvLHRU5hGIlVxmcytJb413Bsu5sPvbE/bM1LOsE=";'
contains "$MODULE" 'pkgs.runCommand "comfyui-mainodes-f4868b4-tested"'
contains "$MODULE" '${comfyPythonEnv}/bin/python tests/test_audio_smear.py'
contains "$MODULE" '${comfyPythonEnv}/bin/python tests/test_timesmear_target_grid.py'
for node in H3JerkOracle H3TimeSmear H3V2VInit H3ExactRecover H3AudioSmear H3AudioRecover H3ManualHoldMap; do
  contains "$MODULE" "\"$node\""
done
contains "$MODULE" 'ln -s ${mainodesNode} "$out/ComfyUI-MAINodes"'

# All public source graphs are byte-pinned before adaptation.
contains "$BUILDER" "7773d9e1b6b795b6d8cc8605e9af1e25fd7a1525992815c77ea5da1b1c7f3d4f 'automatic De-RoPE workflow'"
contains "$BUILDER" "dd055dc1c62c49135706f3cee94cd46b2ef4720d5829f30a731c9e2bf384edba 'targeted De-RoPE workflow'"
contains "$BUILDER" "c1f8613eedab77d275e6ed48e00792a1ceb751a27d3dbe0d3c8a05197bd162c5 'REF2VA De-RoPE workflow'"
contains "$MODULE" '${mainodesSource}/examples/motion_pipeline.json'
contains "$MODULE" '${mainodesSource}/examples/motion_pipeline_targeted.json'
contains "$MODULE" '${mainodesSource}/examples/motion_pipeline_ref2va_audioinit.json'

# Workstation adaptation is full quality and retains the video's 25-step,
# no-Turbo two-pass baseline.
for selector in \
  minimax_h3_fl2va_bf16.safetensors \
  minimax_h3_ref2va_bf16.safetensors \
  qwen3vl_32b_minimax_h3_bf16.safetensors \
  minimax_h3_video_vae_fp16.safetensors \
  minimax_h3_audio_vae_fp32.safetensors; do
  contains "$BUILDER" "$selector"
done
contains "$BUILDER" '["simple", 25, 1]'
contains "$BUILDER" '["simple", 25, 0.5, "faithful detail 0.50 (metric best)"]'
contains "$BUILDER" '["res_multistep"]'
contains "$BUILDER" '.id != 300 and .id != 301 and .id != 302 and .id != 303'
contains "$BUILDER" '([.nodes[] | select(.type == "LoraLoaderModelOnly")] | length) == 0'
contains "$BUILDER" "grep -RqiE 'pruned_int8|nvfp4|int8_convrot|LoraLoaderModelOnly|lightx2v|resolve/main|tree/main|ComfyUI-Manager'"
contains "$BUILDER" '[[ $(find "$output_dir" -type f -name '\''*.json'\'' | wc -l) -eq 3 ]]'

for filename in \
  '01 MiniMax H3 De-RoPE v1.0 - FL2VA Automatic Full BF16 Development.json' \
  '02 MiniMax H3 De-RoPE v1.0 - FL2VA Targeted Full BF16 Development.json' \
  '03 MiniMax H3 De-RoPE v1.0 - REF2VA Audio Full BF16 Development.json'; do
  contains "$BUILDER" "$filename"
done

# Immutable staged installation: a differing v1.0 can never be overwritten.
contains "$MODULE" 'h3_derope_dir="$user_workflows/minimax-h3-derope-development-v1.0"'
contains "$MODULE" 'for source in ${minimaxH3DeropeWorkflows}/workflows/*.json; do'
contains "$MODULE" 'verify_versioned_workflow_install "$h3_derope_staging" "$h3_derope_dir"'
contains "$MODULE" 'install_versioned_workflow_dir "$h3_derope_staging" "$h3_derope_dir"'

# Video findings and limitations stay discoverable beside the workflow.
contains "$RESEARCH" 'https://youtu.be/IlVPJI9ceKM'
contains "$RESEARCH" '2c9db1827306940673de75c07411aa46be3f30e56038aac2bac3a90381ae6f44'
contains "$RESEARCH" '09:22–10:31'
contains "$RESEARCH" 'no Turbo LoRA and 25 shared scheduled steps'
contains "$RUNBOOK" 'This is temporal repair, not conventional interpolation.'
contains "$RUNBOOK" 'This does not guarantee improvement.'
contains "$RUNBOOK" 'Development evidence, not Production authority.'

nix-instantiate --parse "$MODULE" >/dev/null
printf 'PASS: MiniMax H3 De-RoPE v1.0 pins the public Motion Lab source, full-BF16 two-pass workflows, and immutable Development deployment\n'
