#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix/JQ source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-motion-context-workflows.sh"
RUNBOOK="$ROOT/docs/runbooks/minimax-h3-motion-context.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

for file in "$MODULE" "$BUILDER" "$RUNBOOK"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$BUILDER" ]] || fail "$BUILDER is not executable"
bash -n "$BUILDER"
nix-instantiate --parse "$MODULE" >/dev/null

contains "$MODULE" 'repo = "ComfyUI-H3-Motion-Context-MultiRef";'
contains "$MODULE" 'rev = "87de57ba619297503fa49c9594c0c021d5b0c261";'
contains "$MODULE" 'hash = "sha256-tu5Q7keXuZTUN8y4qSeGJqInDNm8WWwB3UQmmGWc4ek=";'
contains "$MODULE" '${comfyPythonEnv}/bin/python tests/run_tests.py'
contains "$MODULE" 'ln -s ${h3MotionContextNode} "$out/ComfyUI-H3-Motion-Context-MultiRef"'
contains "$MODULE" '${../../scripts/comfyui/build-minimax-h3-motion-context-workflows.sh}'
contains "$MODULE" 'h3_motion_context_dir="$user_workflows/minimax-h3-motion-context-development"'
contains "$MODULE" 'for source in ${minimaxH3MotionContextWorkflows}/workflows/*.json; do'

contains "$BUILDER" '85502305f691ece7f64c0c9db6ed5703f95bc79da6f8024014c80fb37112dbdd'
contains "$BUILDER" 'b51189eea08339d054ad92945700408b9edd85580fa6f08f24fc29cda14d9187'
contains "$BUILDER" '01 MiniMax H3 Custom Keyframes - BF16 Base Development.json'
contains "$BUILDER" '02 MiniMax H3 Custom Keyframes - BF16 FL2VA Turbo 4-Step Development.json'
contains "$BUILDER" '03 MiniMax H3 AV Extension - BF16 REF2VA Turbo 4-Step Development.json'
contains "$BUILDER" 'minimax_h3_fl2va_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_ref2va_bf16.safetensors'
contains "$BUILDER" 'minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
contains "$BUILDER" '["simple", 4, 1]'
contains "$BUILDER" '[6, 3]'
contains "$BUILDER" '[12, 3]'
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

printf 'PASS: H3 Motion Context is pinned, source-tested, BF16-adapted, Turbo-family matched, and Development-only\n'
