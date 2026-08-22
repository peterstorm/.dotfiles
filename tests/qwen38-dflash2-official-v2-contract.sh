#!/usr/bin/env bash
# Contract for the official SGLang Qwen3.8-27B + DFlash2 v2 profile.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang-v2.sh"
DOWNLOAD="$ROOT/scripts/inference/qwen38/download-qwen38-27b-dflash2-v2.sh"
SWITCH="$ROOT/scripts/inference/qwen38/switch-qwen38-backend-v3.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
DOC="$ROOT/docs/runbooks/qwen38-27b-dflash2-official-runbook-2026-08-22.md"
IMAGE="lmsysorg/sglang:dev-qwen38-27b-dflash2"
DIGEST="sha256:616a3e97f45191af975896cfa644279096cb31bd408a071c2e99ca7209c3cafe"
AMD64_DIGEST="sha256:b91d664a8e4825afc16ab831c6035a6c88ac20ef8bd26da4fe2b9813a9f44376"
SOURCE_SHA="5f55db35e926d50676f75b812640ea2410b0fe0e"
DRAFT_REV="dedf8df68adfb1afeaf7b7480c0a0243108177b4"
DRAFT_SHA="67fc76d68dc5a9415511a4f394ef744d67510cd20e93b37cc2cc7d28e4bab65c"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

absent() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "$file must not contain: $text"
  fi
}

for file in "$RUN" "$DOWNLOAD" "$SWITCH" "$DOC"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$RUN" "$DOWNLOAD" "$SWITCH"; do
  [[ -x "$file" ]] || fail "$file is not executable"
  bash -n "$file"
done

invalid_status=0
invalid_output="$(MAX_RUNNING_REQUESTS=not-a-number bash "$RUN" 2>&1)" || invalid_status=$?
[[ "$invalid_status" -eq 2 ]] || fail "invalid request count did not fail before I/O with status 2"
grep -Fq 'MAX_RUNNING_REQUESTS must be a positive integer' <<<"$invalid_output" \
  || fail "invalid request count error was not reported"
context_status=0
context_output="$(CONTEXT_LENGTH=262145 bash "$RUN" 2>&1)" || context_status=$?
[[ "$context_status" -eq 2 ]] || fail "oversized native context did not fail with status 2"
grep -Fq 'exceeds the checkpoint-native 262144-token contract' <<<"$context_output" \
  || fail "oversized native context error was not reported"

# Official immutable image and native capability gate.
contains "$RUN" "IMAGE=\"$IMAGE\""
contains "$RUN" "IMAGE_DIGEST=\"$DIGEST\""
contains "$RUN" "IMAGE_SOURCE_SHA=\"$SOURCE_SHA\""
contains "$RUN" 'IMAGE_REF="$IMAGE@$IMAGE_DIGEST"'
contains "$RUN" 'ai.sglang.build.commit'
contains "$RUN" 'DFlash2DraftModel'
contains "$RUN" 'CandidateSelector'
contains "$RUN" 'DFlashGroupedConv'
contains "$RUN" 'DRAFT_CONTAINER="/models/incoai/Qwen3.8-27B-DFlash2"'
absent "$RUN" 'DFlashDraftModel"]'
absent "$RUN" 'DRAFT_SGLANG_HOST'
absent "$RUN" 'cp -a "$DRAFT_HOST"'

# Official RTX PRO 6000 BF16 cell and explicit Mamba admission pin.
contains "$RUN" 'GPU_DEVICE="${GPU_DEVICE:-1}"'
contains "$RUN" '--gpus "\"device=$GPU_DEVICE\""'
contains "$RUN" '-e CUDA_VISIBLE_DEVICES=0'
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--tp-size 1'
contains "$RUN" 'KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8_e4m3}"'
contains "$RUN" 'MAMBA_SSM_DTYPE="${MAMBA_SSM_DTYPE:-float32}"'
contains "$RUN" 'CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"'
contains "$RUN" 'MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"'
contains "$RUN" 'MAMBA_STATE_SLOTS=5'
contains "$RUN" 'MAX_MAMBA_CACHE_SIZE=$((MAX_RUNNING_REQUESTS * MAMBA_STATE_SLOTS))'
contains "$RUN" '--mamba-radix-cache-strategy extra_buffer'
contains "$RUN" '--max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE"'
absent "$RUN" '--mamba-full-memory-ratio'
contains "$RUN" '--attention-backend flashinfer'
contains "$RUN" '--speculative-algorithm DFLASH'
contains "$RUN" '--speculative-num-draft-tokens "$DFLASH2_BLOCK_SIZE"'
contains "$RUN" 'DFLASH2_BLOCK_SIZE=8'

# Existing security and operational boundaries remain intact.
contains "$RUN" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$RUN" 'inference_prepare_api_key "${SGLANG_API_KEY:-${VLLM_API_KEY:-}}"'
contains "$RUN" 'inference_write_private_file "$ENVFILE" <<EOF'
contains "$RUN" 'ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"'
contains "$RUN" 'NAME="qwen38-27b-bf16-dflash2-sglang-v2"'
contains "$RUN" 'CACHE_HOST="/models/sglang-cache/qwen38-bf16-dflash2-official-v2"'
contains "$RUN" 'ENVFILE="$CONFIG_DIR/sglang-dflash2-official-v2.env"'
if grep -Eq '^[[:space:]]*-e SGLANG_API_KEY=' "$RUN"; then
  fail "$RUN exposes SGLANG_API_KEY in Docker argv"
fi

# Canonical downloader pins and verifies the byte-identical official artifact.
contains "$DOWNLOAD" 'REPO="incoai/Qwen3.8-27B-DFlash2"'
contains "$DOWNLOAD" "REV=\"$DRAFT_REV\""
contains "$DOWNLOAD" "MODEL_SHA256=\"$DRAFT_SHA\""
contains "$DOWNLOAD" 'MODEL_SIZE="3848817896"'
contains "$DOWNLOAD" 'CONFIG_SHA256="873e3556509b0da06e29654ba00d4944888d4b5e8a33afde25f7eb27d321e980"'
contains "$DOWNLOAD" 'sha256sum "$CONTAINER_DEST/model.safetensors"'
contains "$DOWNLOAD" 'printf '\''%s\n'\'' "$REPO@$REV" > "$CONTAINER_DEST/.download-complete"'

# Versioned switcher adds the official mode without changing v2 semantics.
contains "$SWITCH" 'DFLASH2_OFFICIAL_NAME="qwen38-27b-bf16-dflash2-sglang-v2"'
contains "$SWITCH" 'DFLASH2_OFFICIAL_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-sglang-v2.sh"'
contains "$SWITCH" 'dflash2-official) START_NAME="$DFLASH2_OFFICIAL_NAME"'
contains "$SWITCH" 'dflash2-official) FALLBACK="dflash2-native"'
contains "$SWITCH" 'dflash2-official|dflash2-vllm'
contains "$CATALOG" 'qwen38-27b-bf16-dflash2-sglang-v2'

# Runbook distinguishes official provenance from local qualification.
contains "$DOC" 'docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B'
contains "$DOC" "$DIGEST"
contains "$DOC" "$AMD64_DIGEST"
contains "$DOC" "$SOURCE_SHA"
contains "$DOC" "$DRAFT_REV"
contains "$DOC" "$DRAFT_SHA"
contains "$DOC" 'desktop was offline'
contains "$DOC" 'boot and serve'

printf 'PASS: official SGLang Qwen3.8 DFlash2 v2 profile is internally consistent\n'
