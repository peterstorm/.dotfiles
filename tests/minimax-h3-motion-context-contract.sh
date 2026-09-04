#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix/JQ source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-motion-context-workflows.sh"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-motion-context.md"
SOURCE_EDIT_NODE="$ROOT/comfyui/custom_nodes/aftersignal_h3_source_edit/nodes.py"
SOURCE_EDIT_TEST="$ROOT/comfyui/custom_nodes/aftersignal_h3_source_edit/test_nodes.py"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

for file in "$MODULE" "$BUILDER" "$RUNBOOK" "$SOURCE_EDIT_NODE" "$SOURCE_EDIT_TEST"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "$BUILDER is not executable"
bash -n "$BUILDER"
nix-instantiate --parse "$MODULE" >/dev/null

contains "$MODULE" 'repo = "ComfyUI-H3-Motion-Context-MultiRef";'
contains "$MODULE" 'rev = "87de57ba619297503fa49c9594c0c021d5b0c261";'
contains "$MODULE" 'hash = "sha256-tu5Q7keXuZTUN8y4qSeGJqInDNm8WWwB3UQmmGWc4ek=";'
contains "$MODULE" 'id=1YVjFwB3twS2MviP-DWSmW84gnRHzzEW-'
contains "$MODULE" 'hash = "sha256-FnuBHZDoMZfaPlg+iNc9zHI/ijdfT3aSwehRodRIojU=";'
contains "$MODULE" 'id=1iSS4Dsb_tfkSAlUinHXH_w5QV1-xU3Wf'
contains "$MODULE" 'hash = "sha256-nn6Jcn7aHNgQQm1WoXr0f+PEmZrHhV2YrUopKTkNXTA=";'
contains "$MODULE" '${comfyPythonEnv}/bin/python tests/run_tests.py'
contains "$MODULE" 'ln -s ${h3MotionContextNode} "$out/ComfyUI-H3-Motion-Context-MultiRef"'
contains "$MODULE" 'ln -s ${aftersignalH3SourceEditNode} "$out/aftersignal_h3_source_edit"'
contains "$MODULE" '${comfyPythonEnv}/bin/python "$out/test_nodes.py"'
contains "$MODULE" '${../../scripts/comfyui/build-minimax-h3-motion-context-workflows.sh}'
contains "$MODULE" '--two-guide-source ${minimaxH3TwoGuideWorkflowSource}'
contains "$MODULE" '--four-guide-source ${minimaxH3FourGuideWorkflowSource}'
contains "$MODULE" 'h3_motion_context_dir="$user_workflows/minimax-h3-motion-context-development"'
contains "$MODULE" 'for source in ${minimaxH3MotionContextWorkflows}/workflows/*.json; do'

contains "$BUILDER" '85502305f691ece7f64c0c9db6ed5703f95bc79da6f8024014c80fb37112dbdd'
contains "$BUILDER" 'b51189eea08339d054ad92945700408b9edd85580fa6f08f24fc29cda14d9187'
contains "$BUILDER" '01 MiniMax H3 Custom Keyframes - BF16 Base Development.json'
contains "$BUILDER" '02 MiniMax H3 Custom Keyframes - BF16 FL2VA Turbo 4-Step Development.json'
contains "$BUILDER" '03 MiniMax H3 AV Extension - BF16 REF2VA Turbo 4-Step Development.json'
contains "$BUILDER" '04 MiniMax H3 Two Guides - Maximum Quality BF16 Development.json'
contains "$BUILDER" '05 MiniMax H3 Two Guides - BF16 FL2VA Turbo 4-Step Development.json'
contains "$BUILDER" '06 MiniMax H3 Four Guides - Maximum Quality BF16 Development.json'
contains "$BUILDER" '07 MiniMax H3 Four Guides - BF16 FL2VA Turbo 4-Step Development.json'
contains "$BUILDER" '167b811d90e83197da3e583e88d73dcc723f8a375f4f7692c1e851a1d448a235'
contains "$BUILDER" '9e7e89727eda1cd810426d56a17af47fe3c4999ac7855d98ad4a2929390d5d30'
contains "$BUILDER" 'minimax_h3_fl2va_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_ref2va_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
contains "$BUILDER" '["simple", 4, 1]'
contains "$BUILDER" '[6, 3]'
contains "$BUILDER" '[12, 3]'
contains "$BUILDER" '362'
contains "$BUILDER" '[73, 160, 234, 324]'
contains "$BUILDER" 'Every guide image is intentionally wired both as an exact-frame guide and as a visual reference.'
contains "$BUILDER" '.widgets_values_named.image = "h3-guides/GUIDE_1.png"'
contains "$BUILDER" 'Gemini_Generated'
contains "$BUILDER" 'Long-form continuity is Creative Montage evidence and cannot prove mechanics.'
contains "$BUILDER" "fl2v_turbo_8step"

if grep -Fq 'ref2v_turbo_4step' "$BUILDER" && ! grep -Fq 'minimax_h3_ref2va_bf16.safetensors' "$BUILDER"; then
  fail 'Ref2V Turbo workflow does not name the matching Ref2VA base family'
fi
if grep -Fq 'fl2v_turbo_4step' "$BUILDER" && ! grep -Fq 'minimax_h3_fl2va_bf16.safetensors' "$BUILDER"; then
  fail 'FL2V Turbo workflow does not name the matching FL2VA base family'
fi

contains "$RUNBOOK" '39 frames'
contains "$RUNBOOK" 'setup → event → consequence'
contains "$RUNBOOK" '15 seconds or less'
contains "$RUNBOOK" 'Mechanics-Proof'
contains "$RUNBOOK" 'four-step'
contains "$RUNBOOK" 'Two Guides — Maximum Quality BF16'
contains "$RUNBOOK" 'Four Guides — BF16 FL2VA Turbo 4-Step'
contains "$RUNBOOK" 'guide and as a visual reference'
contains "$RUNBOOK" 'strong steer, not a compositing guarantee'
contains "$SOURCE_EDIT_NODE" 'AFTERSIGNALH3SourceVideoLatent'
contains "$SOURCE_EDIT_NODE" 'output.pop("noise_mask", None)'
contains "$SOURCE_EDIT_TEST" 'test_source_replaces_video_stream_without_changing_audio'

printf 'PASS: H3 Motion Context is pinned, source-tested, BF16-adapted, Turbo-family matched, and Development-only\n'
