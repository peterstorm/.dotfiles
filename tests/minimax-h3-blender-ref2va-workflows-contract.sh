#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal source text.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-blender-ref2va-workflows.sh"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-blender-ref2va.md"
SKILL="$ROOT/pi/project-skills/creative/blender-previz/SKILL.md"
WORKFLOW="$ROOT/pi/project-skills/creative/blender-previz/references/workflow.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

for file in "$MODULE" "$BUILDER" "$RUNBOOK" "$SKILL" "$WORKFLOW"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "builder is not executable"
bash -n "$BUILDER"
nix-instantiate --parse "$MODULE" >/dev/null

contains "$MODULE" 'minimaxH3BlenderRef2vaWorkflows'
contains "$MODULE" 'build-minimax-h3-blender-ref2va-workflows.sh'
contains "$MODULE" '${qualifiedWorkflowTemplatesJson}/templates/video_minimax_h3_r2v.json'
contains "$MODULE" '${minimaxH3TurboWorkflowSource}/example_workflows/video_minimax_h3_ref2v_lightx2v_turbo.json'
contains "$MODULE" '${minimaxH3PddNode}/example_workflows/pdd_acc_t2v_basic.json'
contains "$MODULE" 'minimax-h3-blender-ref2va-development'
contains "$MODULE" 'h3-blender-previz'

for profile in \
  '01 MiniMax H3 Blender REF2VA - 5s BF16 Quality Development.json' \
  '02 MiniMax H3 Blender REF2VA - 5s Turbo 4-Step Development.json' \
  '03 MiniMax H3 Blender REF2VA - 5s PDD 8-Step Development.json' \
  '04 MiniMax H3 Blender REF2VA - 15s BF16 Quality Development.json' \
  '05 MiniMax H3 Blender REF2VA - 15s Turbo 4-Step Duration Qualification.json' \
  '06 MiniMax H3 Blender REF2VA - 15s PDD 8-Step Duration Qualification.json'; do
  contains "$BUILDER" "$profile"
done

contains "$BUILDER" 'expected_pdd_source_sha=9ef2d4914e3256fb3d025be80b00f28047ea48d41c2d61b10558354b5c23ac69'
contains "$BUILDER" 'minimax_h3_ref2va_bf16.safetensors'
contains "$BUILDER" 'qwen3vl_32b_minimax_h3_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
contains "$BUILDER" 'MiniMax-H3-Ref2VA-Acc-8Step.safetensors'
contains "$BUILDER" 'MiniMaxH3PDDAccApply'
contains "$BUILDER" 'VHS_LoadVideo'
contains "$BUILDER" '"force_rate": 24'
contains "$BUILDER" 'base 5 124'
contains "$BUILDER" 'turbo 5 124'
contains "$BUILDER" 'base 15 362'
contains "$BUILDER" 'turbo 15 362'
contains "$BUILDER" 'Euler/simple, 4 steps, shifts 12/3'
contains "$BUILDER" 'res_multistep, simple scheduler, 20 steps, no acceleration adapter'
contains "$BUILDER" 'NFE 8, strengths 1/1, off-grid error'
contains "$BUILDER" 'Dialogue never creates coverage'
contains "$BUILDER" '"name":"ref_video_audios.ref_video_audio_0","shape":7,"type":"AUDIO","link":null'
contains "$BUILDER" 'No gray proxy material, color-ID material, primitive anatomy'
contains "$BUILDER" '[[ $(find "$output_dir" -type f -name '\''*.json'\'' | wc -l) -eq 6 ]]'

if grep -Fq 'minimax_h3_fl2va_bf16.safetensors' "$BUILDER"; then
  fail "Blender video-carrier suite must remain task-matched Ref2VA"
fi

contains "$RUNBOOK" 'Video 1 is a real REF2VA input'
contains "$RUNBOOK" '124 frames'
contains "$RUNBOOK" '362 frames'
contains "$RUNBOOK" 'Turbo 4-Step'
contains "$RUNBOOK" 'PDD 8-Step'
contains "$RUNBOOK" 'never stack Turbo and PDD'
contains "$RUNBOOK" 'audio output is deliberately unconnected'
contains "$RUNBOOK" 'not deterministic pixel-space transfer'
contains "$SKILL" 'minimax-h3-blender-ref2va-development'
contains "$WORKFLOW" '15-second Turbo and PDD profiles are duration-qualification candidates'

printf 'PASS: Blender REF2VA workflows preserve task family, video-carrier authority, BF16/Turbo/PDD recipes, durations, and Development status\n'
