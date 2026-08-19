#!/usr/bin/env bash
# Static contract for the 2026-08-19 Qwen3.8 REAL DFlash 2 profile — the full
# BF16, TP2, native-engine launcher (run-qwen38-27b-bf16-dflash2-sglang-native.sh).
#
# It is the "make DFlash 2 actually work" sibling of the surgery launcher:
#   * Full BF16 everywhere — no FP8 body, no FP8 KV cache, no quantized draft.
#   * TP2 (two GPUs), identical quality-profile flags to the surgery sibling.
#   * Defaults to the PR #35371 merge-commit image BY TAG so a locally built,
#     never-pushed image resolves (the surgery sibling's mandatory IMAGE@DIGEST
#     cannot address a digest-less local image); pins by digest only when one
#     is supplied.
#   * REQUIRES native DFlash2DraftModel registration and FAILS CLOSED with no
#     surgery fallback — the v1 class silently drops the selector/conv tensors.
#   * switch-qwen38-backend-v2.sh gains a 'dflash2-native' mode, falling back
#     to the surgery 'dflash2' profile.
#
# No GPU, container, or network access is required.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang-native.sh"
SURGERY="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang.sh"
SWITCHER="$ROOT/scripts/inference/qwen38/switch-qwen38-backend-v2.sh"
BUILD="$ROOT/scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

absent() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" && fail "$file must NOT contain: $text"
  return 0
}

for file in "$NATIVE" "$SURGERY" "$SWITCHER" "$BUILD"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$NATIVE" ]] || fail "$NATIVE is not executable"
bash -n "$NATIVE"

# --- full BF16: no FP8 anywhere --------------------------------------------
contains "$NATIVE" '--dtype bfloat16'
contains "$NATIVE" '--kv-cache-dtype bfloat16'
absent   "$NATIVE" '--quantization'
absent   "$NATIVE" 'fp8'
absent   "$NATIVE" '--speculative-draft-model-quantization'
absent   "$NATIVE" 'fp8_e4m3'

# --- TP2, two-GPU quality profile (matches the surgery sibling) ------------
contains "$NATIVE" '--tp-size 2'
contains "$NATIVE" 'GPU_ORDER="${GPU_ORDER:-1,0}"'
contains "$NATIVE" 'expected two queryable GPUs'
contains "$NATIVE" 'MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"'
contains "$NATIVE" 'CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"'
contains "$NATIVE" 'MAMBA_STATE_SLOTS="${MAMBA_STATE_SLOTS:-5}"'
contains "$NATIVE" 'MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * MAMBA_STATE_SLOTS))}"'
contains "$NATIVE" '--attention-backend flashinfer'
contains "$NATIVE" '--mamba-ssm-dtype float32'
contains "$NATIVE" '--mamba-radix-cache-strategy extra_buffer'

# --- real DFlash 2: merge-commit image by tag, digest optional -------------
contains "$NATIVE" 'IMAGE="${DFLASH2_NATIVE_IMAGE:-peterstorm/sglang:qwen38-dflash2-c14312a}"'
contains "$NATIVE" 'DIGEST="${DFLASH2_NATIVE_IMAGE_DIGEST:-}"'
contains "$NATIVE" 'IMAGE_REF="$IMAGE@$DIGEST"'
contains "$NATIVE" 'IMAGE_REF="$IMAGE"'
# The run and both probes must address IMAGE_REF (tag or tag@digest), never a
# hardcoded digest reference.
if grep -Eq -- '"\$IMAGE@\$DIGEST"[^A-Za-z]' "$NATIVE" && ! grep -Fq 'IMAGE_REF="$IMAGE@$DIGEST"' "$NATIVE"; then
  fail "$NATIVE references \$IMAGE@\$DIGEST outside the IMAGE_REF assignment"
fi
contains "$NATIVE" 'docker run -d --init'
contains "$NATIVE" '"$IMAGE_REF" \'

# --- fail closed: native DFlash 2 required, NO surgery ---------------------
contains "$NATIVE" "hasattr(m, 'DFlash2DraftModel')"
contains "$NATIVE" 'does not register DFlash2DraftModel natively'
contains "$NATIVE" 'no surgery fallback'
contains "$NATIVE" 'serving the canonical DFlash 2 tree (no surgery)'
# The canonical tree is mounted directly — no isolated surgery copy, no jq
# rewrite of architectures.
contains "$NATIVE" '-v "$DRAFT_HOST":"$DRAFT_CONTAINER":ro'
absent   "$NATIVE" 'DFlashDraftModel"]'
absent   "$NATIVE" 'cp -a "$DRAFT_HOST"'
absent   "$NATIVE" 'DRAFT_SGLANG_HOST'

# --- distinct identity from the surgery sibling ----------------------------
contains "$NATIVE" 'NAME="qwen38-27b-bf16-dflash2-sglang-native"'
contains "$NATIVE" 'ENVFILE="$CONFIG_DIR/sglang-dflash2-native.env"'
contains "$NATIVE" 'CACHE_HOST="/models/sglang-cache/qwen38-bf16-dflash2-native"'
# Must not collide with the surgery sibling's container name / cache / env.
if [[ "$(grep -c 'NAME="qwen38-27b-bf16-dflash2-sglang"' "$SURGERY")" -eq 0 ]]; then
  fail "surgery sibling changed its container name; the native profile's isolation assumption is stale"
fi

# --- spec flags: DFLASH width 8, no DSPARK residue -------------------------
contains "$NATIVE" 'DFLASH2_BLOCK_SIZE="${DFLASH2_BLOCK_SIZE:-8}"'
contains "$NATIVE" '--speculative-algorithm DFLASH'
contains "$NATIVE" '--speculative-draft-model-path "$DRAFT_CONTAINER"'
contains "$NATIVE" '--speculative-num-draft-tokens "$DFLASH2_BLOCK_SIZE"'
absent   "$NATIVE" '--speculative-algorithm DSPARK'
absent   "$NATIVE" '--speculative-dspark-block-size'

# --- shared secure plumbing (same as every other profile) ------------------
contains "$NATIVE" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$NATIVE" 'inference_resolve_operator'
contains "$NATIVE" 'inference_prepare_api_key "${SGLANG_API_KEY:-${VLLM_API_KEY:-}}"'
contains "$NATIVE" 'ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"'
contains "$NATIVE" 'nvidia-smi --query-gpu=index,power.limit'
contains "$NATIVE" '--enable-metrics'
contains "$NATIVE" '--reasoning-parser qwen3'
contains "$NATIVE" '--tool-call-parser qwen3_coder'
if grep -Eq '^[[:space:]]*-e SGLANG_API_KEY=' "$NATIVE"; then
  fail "$NATIVE exposes SGLANG_API_KEY in Docker command arguments"
fi

# --- switcher: dflash2-native mode, fallback to the surgery dflash2 profile -
contains "$SWITCHER" 'DFLASH2_NATIVE_NAME="qwen38-27b-bf16-dflash2-sglang-native"'
contains "$SWITCHER" 'DFLASH2_NATIVE_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-sglang-native.sh"'
contains "$SWITCHER" '"$DFLASH2_NATIVE_NAME"'
contains "$SWITCHER" 'dflash2-native) START_NAME="$DFLASH2_NATIVE_NAME"'
contains "$SWITCHER" 'dflash2-native) FALLBACK="dflash2"'
contains "$SWITCHER" 'status|vllm|sglang|dflash2|v1-vllm|v1-sglang|dflash2-native'
bash -n "$SWITCHER"

# --- image build target the native profile depends on ----------------------
contains "$BUILD" 'IMAGE="peterstorm/sglang:qwen38-dflash2-c14312a"'
contains "$BUILD" 'DFlash2DraftModel'

printf 'PASS: Qwen3.8 native DFlash 2 (full BF16, TP2) profile contract is internally consistent\n'
