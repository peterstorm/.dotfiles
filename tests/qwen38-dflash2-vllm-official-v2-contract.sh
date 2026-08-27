#!/usr/bin/env bash
# Contract for the fixed official vLLM Qwen3.8-27B + DFlash2 v2 profile.
# No GPU, image pull, or model files are required.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-vllm-v2.sh"
PULL="$ROOT/scripts/inference/qwen38/pull-qwen38-dflash2-vllm-v2-image.sh"
SWITCH="$ROOT/scripts/inference/qwen38/switch-qwen38-backend-v4.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
DOC="$ROOT/docs/runbooks/qwen38-27b-dflash2-vllm-official-runbook-2026-08-25.md"
IMAGE="vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
DIGEST="sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674"
AMD64_DIGEST="sha256:2786e1d3301cb1039a3695c20aafd15b608adefd4c8380c2ed1457b24813c4a4"
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
order_status=0
order_output="$(GPU_ORDER=0,0 bash "$RUN" 2>&1)" || order_status=$?
[[ "$order_status" -eq 2 ]] || fail "duplicate physical GPU order did not fail with status 2"
grep -Fq 'must contain both physical GPUs exactly once' <<<"$order_output" \
  || fail "invalid physical GPU order error was not reported"

# Immutable official image and regression-aware capability gate.
contains "$RUN" "IMAGE=\"$IMAGE\""
contains "$RUN" "IMAGE_DIGEST=\"$DIGEST\""
contains "$RUN" "IMAGE_AMD64_DIGEST=\"$AMD64_DIGEST\""
contains "$RUN" "IMAGE_SOURCE_SHA=\"$SOURCE_SHA\""
contains "$RUN" 'IMAGE_REF="$IMAGE@$IMAGE_DIGEST"'
contains "$RUN" 'ai.vllm.build.commit'
contains "$RUN" 'Qwen3_5ForConditionalGeneration'
contains "$RUN" 'DFlash2DraftModel'
contains "$RUN" 'DFlash2Speculator'
contains "$RUN" 'decoder_layer_cls = DFlashQwen3DecoderLayer'
contains "$RUN" 'self.decoder_layer_cls('
absent "$RUN" 'peterstorm/vllm:qwen38-dflash2-pr52816'
absent "$RUN" 'build-qwen38-dflash2-vllm-image.sh'

# Canonical checkpoints and fixed seven-token Qwen recipe geometry.
contains "$RUN" 'DRAFT_HOST="${DFLASH2_DRAFT_HOST:-$INFERENCE_OPERATOR_HOME/Desktop/Qwen3.8-27B-DFlash2}"'
contains "$RUN" 'DRAFT_CONTAINER="/models/incoai/Qwen3.8-27B-DFlash2"'
contains "$RUN" 'DRAFT_PIN="incoai/Qwen3.8-27B-DFlash2@dedf8df68adfb1afeaf7b7480c0a0243108177b4"'
contains "$RUN" 'grep -Fxq "$DRAFT_PIN" "$DRAFT_HOST/.download-complete"'
contains "$RUN" 'DFLASH2_NUM_SPEC_TOKENS=7'
absent "$RUN" 'DFLASH2_NUM_SPEC_TOKENS="${'
contains "$RUN" '.architectures == ["DFlash2DraftModel"] and .dflash_config.block_size == 8'
contains "$RUN" '3848817896'
absent "$RUN" 'DFlashDraftModel"]'
absent "$RUN" 'DRAFT_SGLANG_HOST'

# Preserve the measured TP2/BF16 shape for an engine-only A/B.
contains "$RUN" 'GPU_ORDER="${GPU_ORDER:-1,0}"'
contains "$RUN" '-e CUDA_VISIBLE_DEVICES="$GPU_ORDER"'
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--kv-cache-dtype auto'
contains "$RUN" '--mamba-ssm-cache-dtype float32'
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--enable-chunked-prefill'
contains "$RUN" '\"method\":\"dflash\"'
contains "$RUN" '--attention-backend flashinfer'
contains "$RUN" '--reasoning-parser qwen3'
contains "$RUN" '--tool-call-parser qwen3_coder'
contains "$RUN" '--default-chat-template-kwargs'
contains "$RUN" '--override-generation-config'

# Security, isolation, and pre-mutation checks.
contains "$RUN" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$RUN" 'inference_prepare_api_key "${VLLM_API_KEY:-}"'
contains "$RUN" 'inference_write_private_file "$ENVFILE" <<EOF'
contains "$RUN" 'NAME="qwen38-27b-bf16-dflash2-vllm-v2"'
contains "$RUN" 'CACHE_HOST="/models/vllm-cache/qwen38-bf16-dflash2-official-v2"'
contains "$RUN" 'ENVFILE="$CONFIG_DIR/vllm-dflash2-official-v2.env"'
contains "$RUN" 'nvidia-smi --query-gpu=index,power.limit,memory.used'
contains "$RUN" 'MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"'
contains "$RUN" 'inference_install_private_dir "$CONTAINER_ARCHIVE_DIR"'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "$RUN exposes VLLM_API_KEY in Docker argv"
fi

# Dedicated pull path: exact digest and source proof, never a local build.
contains "$PULL" "IMAGE=\"$IMAGE\""
contains "$PULL" "IMAGE_DIGEST=\"$DIGEST\""
contains "$PULL" "IMAGE_SOURCE_SHA=\"$SOURCE_SHA\""
contains "$PULL" 'docker pull "$IMAGE_REF"'
contains "$PULL" 'ai.vllm.build.commit'
contains "$PULL" 'VLLM_DFLASH2_OFFICIAL_V2_PULL_COMPLETE'
absent "$PULL" 'docker build'

# V4 switcher adds one new mode and falls back to the measured PR artifact.
contains "$SWITCH" 'DFLASH2_VLLM_OFFICIAL_NAME="qwen38-27b-bf16-dflash2-vllm-v2"'
contains "$SWITCH" 'DFLASH2_VLLM_OFFICIAL_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-vllm-v2.sh"'
contains "$SWITCH" 'dflash2-vllm-official) START_NAME="$DFLASH2_VLLM_OFFICIAL_NAME"'
contains "$SWITCH" 'dflash2-vllm-official) FALLBACK="dflash2-vllm"'
contains "$SWITCH" 'dflash2-vllm|dflash2-vllm-official) ;;'
contains "$CATALOG" 'qwen38-27b-bf16-dflash2-vllm-v2'

# Research receipt separates official support from local promotion.
contains "$DOC" 'vllm-project/vllm/pull/52816'
contains "$DOC" 'vllm-project/vllm/pull/53435'
contains "$DOC" 'vllm-project/recipes/pull/837'
contains "$DOC" "$DIGEST"
contains "$DOC" "$AMD64_DIGEST"
contains "$DOC" "$SOURCE_SHA"
contains "$DOC" 'desktop was not contacted'
contains "$DOC" '#53477'
contains "$DOC" 'custom source build is no longer the preferred artifact'

printf 'PASS: official vLLM Qwen3.8 DFlash2 v2 profile is internally consistent\n'
