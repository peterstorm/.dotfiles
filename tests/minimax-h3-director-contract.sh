#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal Nix source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MODULE="$ROOT/machines/desktop/comfyui.nix"
BUILDER="$ROOT/scripts/comfyui/build-minimax-h3-director-workflows.sh"
HARDENER="$ROOT/scripts/comfyui/harden-minimax-h3-director.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local needle=$1
  grep -Fq -- "$needle" "$MODULE" || fail "missing Director module contract: $needle"
}

builder_contains() {
  local needle=$1
  grep -Fq -- "$needle" "$BUILDER" || fail "missing Director builder contract: $needle"
}

hardener_contains() {
  local needle=$1
  grep -Fq -- "$needle" "$HARDENER" || fail "missing Director hardener contract: $needle"
}

contains 'repo = "ComfyUI_MiniMaxH3_Director";'
contains 'rev = "bdefc5f8037aad286ff1aa3d908dfb3cf13b080b";'
contains 'hash = "sha256-a4C72dV9K9AXWD70+LIvOTQLawTfUrRzyylM16E1J/w=";'
contains 'ln -s ${minimaxH3DirectorNode} "$out/ComfyUI_MiniMaxH3_Director"'
contains '${../../scripts/comfyui/harden-minimax-h3-director.sh}'
contains 'MINIMAX_H3_DIRECTOR_LLM_API_KEY_FILE = "/home/peterstorm/.config/qwen38/api-key";'
contains 'scenedetect'
hardener_contains 'replace(relative, "weights_only=False", "weights_only=True")'
hardener_contains 'set("llm_api_key", "");'
hardener_contains 'const DEFAULT_API_FORMAT = "OpenAI Compatible";'
hardener_contains 'const DEFAULT_LLM_URL = "http://127.0.0.1:8000/v1";'
hardener_contains 'DEFAULT_OLLAMA_MODEL = "qwen3.8-27b"'
contains '${../../scripts/comfyui/build-minimax-h3-director-workflows.sh}'
contains 'director_dir="$user_workflows/minimax-h3-director-local-development"'
contains 'for source in ${minimaxH3DirectorWorkflows}/workflows/*.json; do'
builder_contains '01 MiniMax H3 Director REF2VA - BF16 Full Quality Development.json'
builder_contains '02 MiniMax H3 Director REF2VA - Qualified Turbo 4-Step Development.json'
builder_contains '"minimax_h3_ref2va_bf16.safetensors"'
builder_contains '"qwen3vl_32b_minimax_h3_bf16.safetensors"'
builder_contains '"minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors", 1.0'
builder_contains '[[50,"res_multistep","beta",12,3]]'
builder_contains '[[4,"euler","simple",12,3]]'
builder_contains 'The RHEA Hush visual result was user-affirmed as great; its dialogue performance was separately rejected as robotic.'
builder_contains '.output.refImageSize = "match"'

if grep -Fq 'minimax_h3_fl2v_turbo' "$BUILDER"; then
  fail 'Director package substitutes an FL2VA Turbo adapter into the Ref2VA profile'
fi

bash -n "$BUILDER"
bash -n "$HARDENER"
nix-instantiate --parse "$MODULE" >/dev/null
printf 'PASS: H3 Director is pinned, credential-safe, BF16-first, and retains the qualified Ref2VA Turbo profile\n'
