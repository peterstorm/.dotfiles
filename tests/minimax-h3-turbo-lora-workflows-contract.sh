#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-turbo-lora-workflows.sh"

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
contains '${../../scripts/comfyui/build-minimax-h3-turbo-lora-workflows.sh}'
contains 'h3_turbo_dir="$user_workflows/minimax-h3-turbo-lora-qualification"'

builder_contains '00 MiniMax H3 BF16 FL2VA Turbo 8-Step - Prompt Only Mechanics Test.json'
builder_contains '01 MiniMax H3 BF16 FL2VA Turbo 4-Step 768p - First Last Test.json'
builder_contains '02 MiniMax H3 BF16 FL2VA Turbo 8-Step - First Last Test.json'
builder_contains '03 MiniMax H3 BF16 REF2VA Turbo 4-Step - Reference Test.json'
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

bash -n "$BUILDER"
nix-instantiate --parse "$MODULE" >/dev/null
printf 'PASS: MiniMax H3 Turbo qualification workflows pin task family, LoRA, steps, shifts, resolution, and Development status\n'
