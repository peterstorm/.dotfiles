#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-turbo-lora-workflows.sh"
DOWNLOADER="$ROOT/scripts/comfyui/download-minimax-h3-pdd-models.sh"
RUNBOOK="$ROOT/docs/runbooks/comfyui-krea2-minimax-h3-muse-runbook.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local needle=$1
  grep -Fq -- "$needle" "$MODULE" || fail "missing module contract: $needle"
}

builder_contains() {
  local needle=$1
  grep -Fq -- "$needle" "$BUILDER" || fail "missing builder contract: $needle"
}

contains 'repo = "Minimax-H3-Turbo";'
contains 'rev = "a7e148b8dc7db8ad976966060dcc022adf11fc8d";'
contains 'hash = "sha256-LG7fqEcWcuacQYK6DMyS7uCTnz0Wa66oO6SPRIqIENo=";'
contains 'repo = "ComfyUI-MiniMax-H3-PDD-Acc";'
contains 'rev = "311a65dd53832d8a5f8177a9d5fb923c09e35a90";'
contains 'hash = "sha256-jqjqdww2pUYPOr+5ox0GtculgpL1OjKGlgALb4eN1vk=";'
contains '${comfyPythonEnv}/bin/python tests/test_pdd_acc.py'
contains 'ln -s ${minimaxH3PddNode} "$out/ComfyUI-MiniMax-H3-PDD-Acc"'
contains '"pdd_acc"'
contains '${../../scripts/comfyui/build-minimax-h3-turbo-lora-workflows.sh}'
contains '--pdd-source ${minimaxH3PddNode}/example_workflows/pdd_acc_t2v_basic.json'
contains 'h3_turbo_dir="$user_workflows/minimax-h3-turbo-lora-qualification"'

builder_contains '00 MiniMax H3 BF16 FL2VA Turbo 8-Step - Prompt Only Mechanics Test.json'
builder_contains '01 MiniMax H3 BF16 FL2VA Turbo 4-Step 768p - First Last Test.json'
builder_contains '02 MiniMax H3 BF16 FL2VA Turbo 8-Step - First Last Test.json'
builder_contains '03 MiniMax H3 BF16 REF2VA Turbo 4-Step - Reference Test.json'
builder_contains '04 MiniMax H3 BF16 FL2VA PDD Acc 8-Step - Prompt Test.json'
builder_contains '05 MiniMax H3 BF16 REF2VA PDD Acc 8-Step - Reference Test.json'
builder_contains 'MiniMax-H3-FL2VA-Acc-8Step.safetensors'
builder_contains 'MiniMax-H3-Ref2VA-Acc-8Step.safetensors'
builder_contains 'MiniMaxH3PDDAccApply'
builder_contains 'PDD distills do not stack with Turbo or other acceleration LoRAs.'
builder_contains 'minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors'
builder_contains 'minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors'
builder_contains 'minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors'
builder_contains '4 6 0.98 1344 768'
builder_contains '8 12 0.4 864 480'
builder_contains '["simple", 4, 1]'
builder_contains '["simple", 8, 1]'
builder_contains 'reference resize `match`'
builder_contains 'Do not request internal cuts'
builder_contains 'It is not zero-reference Ref2VA and is not a dedicated T2VA checkpoint.'
builder_contains 'This profile is unqualified'
builder_contains 'previously qualified speed profile'

if grep -Fq 'fl2v_turbo' "$BUILDER" && ! grep -Fq 'minimax_h3_fl2va_bf16.safetensors' "$BUILDER"; then
  fail 'FL2VA Turbo profiles do not name the matching BF16 task family'
fi
if grep -Fq 'ref2v_turbo' "$BUILDER" && ! grep -Fq 'minimax_h3_ref2va_bf16.safetensors' "$BUILDER"; then
  fail 'Ref2VA Turbo profile does not name the matching BF16 task family'
fi

for file in "$BUILDER" "$DOWNLOADER"; do
  [[ -x "$file" ]] || fail "missing executable: $file"
  bash -n "$file"
done
builder_contains '[[ $(find "$output_dir" -type f -name '\''*.json'\'' | wc -l) -eq 6 ]]'

grep -Fq 'REPO="alibaba-pai/MiniMax-H3-Acc-LoRAs"' "$DOWNLOADER" || fail 'PDD downloader repository is not pinned'
grep -Fq 'REV="335001fb9e5455d68a0caa18ec2e319072150328"' "$DOWNLOADER" || fail 'PDD downloader revision is not pinned'
grep -Fq '0b29be7042d883970eb0c20774a9ba03d95669ed80a721bb4d21be8ea0d0a196 1372450680 pdd_acc/MiniMax-H3-FL2VA-Acc-8Step.safetensors' "$DOWNLOADER" || fail 'FL2VA PDD artifact is not exact'
grep -Fq '111c82e669f6e20e628228172edf39395f1a9fc3ad049793895e542c0f55b18c 1372450680 pdd_acc/MiniMax-H3-Ref2VA-Acc-8Step.safetensors' "$DOWNLOADER" || fail 'Ref2VA PDD artifact is not exact'
grep -Fq 'MINIMAX_H3_ACCEPT_LICENSE' "$DOWNLOADER" || fail 'PDD downloader lacks the base-license gate'
grep -Fq 'MINIMAX_H3_AUTHORIZED' "$DOWNLOADER" || fail 'PDD downloader lacks the authorization gate'

grep -Fq 'PDD Acceleration 8-Step' "$RUNBOOK" || fail 'runbook omits PDD qualification'
grep -Fq 'not ordinary LoRAs' "$RUNBOOK" || fail 'runbook omits PDD loader distinction'

nix-instantiate --parse "$MODULE" >/dev/null
printf 'PASS: MiniMax H3 acceleration qualification pins task families, Turbo/PDD loaders, schedules, models, and Development status\n'
