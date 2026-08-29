#!/usr/bin/env bash
# Contract for the immutable vLLM Qwen3.8-27B DFlash2 TP1/BF16-KV profile.
# No GPU, image pull, or model files are required.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-vllm-v3.sh"
PULL="$ROOT/scripts/inference/qwen38/pull-qwen38-dflash2-vllm-v2-image.sh"
SWITCH="$ROOT/scripts/inference/qwen38/switch-qwen38-backend-v5.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
DOC="$ROOT/docs/runbooks/qwen38-27b-dflash2-vllm-tp1-bf16kv-v3-runbook-2026-08-29.md"
IMAGE="vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
DIGEST="sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674"
SOURCE_SHA="a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
absent() { grep -Fq -- "$2" "$1" && fail "$1 must not contain: $2"; return 0; }

for file in "$RUN" "$PULL" "$SWITCH" "$DOC"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$RUN" "$PULL" "$SWITCH"; do
  [[ -x "$file" ]] || fail "$file is not executable"
  bash -n "$file"
done

invalid_status=0
invalid_output="$(MAX_NUM_SEQS=invalid bash "$RUN" 2>&1)" || invalid_status=$?
[[ "$invalid_status" -eq 2 ]] || fail "invalid scheduler cap did not fail before I/O with status 2"
grep -Fq 'MAX_NUM_SEQS must be a positive integer' <<<"$invalid_output" \
  || fail "invalid scheduler cap error was not reported"
context_status=0
context_output="$(MAX_MODEL_LEN=262145 bash "$RUN" 2>&1)" || context_status=$?
[[ "$context_status" -eq 2 ]] || fail "oversized native context did not fail with status 2"
grep -Fq 'exceeds the checkpoint-native 262144-token contract' <<<"$context_output" \
  || fail "oversized native context error was not reported"

# Same immutable target, draft, and official vLLM artifact as v2.
contains "$RUN" 'MODEL_HOST="/models/Qwen3.8-27B"'
contains "$RUN" "IMAGE=\"$IMAGE\""
contains "$RUN" "IMAGE_DIGEST=\"$DIGEST\""
contains "$RUN" "IMAGE_SOURCE_SHA=\"$SOURCE_SHA\""
contains "$RUN" 'ai.vllm.build.commit'
contains "$RUN" 'Qwen3_5ForConditionalGeneration'
contains "$RUN" 'DFlash2DraftModel'
contains "$RUN" 'DFlash2Speculator'
contains "$RUN" 'decoder_layer_cls = DFlashQwen3DecoderLayer'
contains "$RUN" 'DRAFT_PIN="incoai/Qwen3.8-27B-DFlash2@dedf8df68adfb1afeaf7b7480c0a0243108177b4"'
contains "$RUN" 'DFLASH2_NUM_SPEC_TOKENS=7'
absent "$RUN" 'DFLASH2_NUM_SPEC_TOKENS="${'

# Immutable GPU0/TP1/BF16-KV shape leaves GPU1 to ComfyUI.
contains "$RUN" 'GPU_DEVICE=0'
contains "$RUN" '--gpus "device=$GPU_DEVICE"'
contains "$RUN" '-e CUDA_VISIBLE_DEVICES=0'
contains "$RUN" '--tensor-parallel-size 1'
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--kv-cache-dtype auto'
contains "$RUN" '--mamba-ssm-cache-dtype float32'
contains "$RUN" 'CUDA_VISIBLE_DEVICES=1'
contains "$RUN" 'active ComfyUI is not proven pinned to physical GPU1'
contains "$RUN" 'nvidia-smi --id="$GPU_DEVICE"'
absent "$RUN" 'GPU_ORDER='
absent "$RUN" '--gpus all'

# Context, scheduler, cache, identity, and security are isolated from v2.
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--enable-chunked-prefill'
contains "$RUN" '\"method\":\"dflash\"'
contains "$RUN" 'NAME="qwen38-27b-bf16-dflash2-vllm-v3"'
contains "$RUN" 'CACHE_HOST="/models/vllm-cache/qwen38-bf16-dflash2-tp1-bf16kv-v3"'
contains "$RUN" 'ENVFILE="$CONFIG_DIR/vllm-dflash2-tp1-bf16kv-v3.env"'
contains "$RUN" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$RUN" 'inference_prepare_api_key "${VLLM_API_KEY:-}"'
contains "$RUN" 'inference_write_private_file "$ENVFILE" <<EOF'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "$RUN exposes VLLM_API_KEY in Docker argv"
fi

# V5 exposes the profile and falls back to the official TP2 v2 profile.
contains "$SWITCH" 'DFLASH2_VLLM_TP1_BF16KV_NAME="qwen38-27b-bf16-dflash2-vllm-v3"'
contains "$SWITCH" 'DFLASH2_VLLM_TP1_BF16KV_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-vllm-v3.sh"'
contains "$SWITCH" 'dflash2-vllm-tp1-bf16kv) START_NAME="$DFLASH2_VLLM_TP1_BF16KV_NAME"'
contains "$SWITCH" 'dflash2-vllm-tp1-bf16kv) FALLBACK="dflash2-vllm-official"'
contains "$CATALOG" 'qwen38-27b-bf16-dflash2-vllm-v3'

contains "$DOC" 'physical GPU:'
contains "$DOC" 'ComfyUI physical GPU:'
contains "$DOC" 'BF16-KV'
contains "$DOC" "$DIGEST"

printf 'PASS: vLLM Qwen3.8 DFlash2 TP1/BF16-KV v3 profile is internally consistent\n'
