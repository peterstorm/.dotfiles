#!/usr/bin/env bash
# Static contract for the 2026-08-18 v2 Qwen3.8 DSpark profiles:
#
#   * download-qwen38-27b-dspark-v2.sh pins the draft revision 85ef153
#     (dflash.py verify-window fix; weights byte-identical to 923ed3a) and
#     writes to the SEPARATE /models/Qwen3.8-27B-DSpark-v2 tree.
#   * run-qwen38-27b-bf16-dspark-vllm-v2.sh re-pins the vLLM DSpark image to
#     nightly-aa99034 (upstream aa99034, 2026-08-18) with the per-arch
#     manifest digest, mounts the v2 draft tree, uses a v2 container name,
#     and retains the draft-config surgery (now redundant upstream via
#     #52197 but image-independent and idempotent).
#   * run-qwen38-27b-bf16-dspark-sglang-v2.sh keeps the pinned qwen38-27b
#     image, uses the v2 draft tree, and switches the mamba pin to the
#     08-17 SGLang cookbook formula: target_concurrency x S (S=5 for
#     extra_buffer), D excluded — the engine sizes the verify buffer
#     separately, so folding D in over-provisions the GDN state pool.
#   * The 08-16 profiles stay intact with their original pins: this is a
#     side-by-side rollout, not a replacement.
#
# No GPU, container, or network access is required.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V2_DL="$ROOT/scripts/inference/qwen38/download-qwen38-27b-dspark-v2.sh"
V2_SGLANG="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-sglang-v2.sh"
V2_VLLM="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-vllm-v2.sh"
OLD_DL="$ROOT/scripts/inference/qwen38/download-qwen38-27b-dspark.sh"
OLD_SGLANG="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-sglang.sh"
OLD_VLLM="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-vllm.sh"
DOC="$ROOT/docs/runbooks/qwen38-27b-runbook-2026-08-18.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for file in "$V2_DL" "$V2_SGLANG" "$V2_VLLM" "$OLD_DL" "$OLD_SGLANG" "$OLD_VLLM" "$DOC"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$V2_DL" "$V2_SGLANG" "$V2_VLLM"; do
  [[ -x "$file" ]] || fail "$file is not executable"
  bash -n "$file"
done

command -v jq >/dev/null 2>&1 || fail "jq is required for the surgery assertion"

# --- v2 downloader: new draft revision, separate tree -----------------------
contains "$V2_DL" 'REPO="RadixArk/Qwen3.8-27B-DSpark"'
contains "$V2_DL" 'REV="85ef153be924f17ce4bf62726954eeaa4a73e854"'
contains "$V2_DL" 'DEST="/models/Qwen3.8-27B-DSpark-v2"'
contains "$V2_DL" 'export HF_HUB_DISABLE_XET=1'
if grep -Fq '923ed3a8572615643f0137e424e4ce4edd7f1cda' "$V2_DL"; then
  fail "$V2_DL still pins the 08-16 draft revision"
fi
if grep -Eq 'DEST="/models/Qwen3\.8-27B-DSpark"' "$V2_DL"; then
  fail "$V2_DL writes to the 08-16 draft tree"
fi

# --- v2 vLLM DSpark: new nightly pin, v2 trees and container ----------------
contains "$V2_VLLM" 'IMAGE="vllm/vllm-openai:nightly-aa9903490c616dc6871e5acc62cec7bb1e5e9434"'
contains "$V2_VLLM" 'DIGEST="sha256:7eb4028507367e69cb0abfa213042d1814c27c1b499af45fbffec8f16d9cbc6f"'
if grep -Fq 'nightly-ac7509e2b1db40fec2f03dde1ed4e9dfdc2338c9' "$V2_VLLM"; then
  fail "$V2_VLLM still pins the 08-16 vLLM nightly"
fi
contains "$V2_VLLM" 'DRAFT_HOST="/models/Qwen3.8-27B-DSpark-v2"'
contains "$V2_VLLM" 'DRAFT_VLLM_HOST="/models/Qwen3.8-27B-DSpark-vllm-v2"'
contains "$V2_VLLM" 'DRAFT_CONTAINER="/models/RadixArk/Qwen3.8-27B-DSpark-vllm-v2"'
contains "$V2_VLLM" 'NAME="qwen38-27b-bf16-dspark-vllm-v2"'
contains "$V2_VLLM" 'ENVFILE="$CONFIG_DIR/vllm-dspark-v2.env"'

# Draft config surgery retained (now redundant upstream via #52197, but the
# launcher must keep routing on any image): rewrite architectures on an
# ISOLATED copy, only when needed.
contains "$V2_VLLM" 'cp -a "$DRAFT_HOST" "${DRAFT_VLLM_HOST}.tmp"'
contains "$V2_VLLM" "jq -e '.architectures == [\"Qwen3DSparkModel\"]'"
if grep -Eq -- 'jq [^|]*"\$DRAFT_HOST' "$V2_VLLM"; then
  fail "$V2_VLLM rewrites the shared draft copy in place instead of an isolated vLLM copy"
fi
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/config.json" <<'JSON'
{"architectures":["DSparkDraftModel"],"block_size":7,"dflash_config":{"target_layer_ids":[4,16,28,40,52]}}
JSON
jq '(.architectures = ["Qwen3DSparkModel"])' "$fixture/config.json" > "$fixture/out.json"
jq -e '.architectures == ["Qwen3DSparkModel"] and .block_size == 7 and .dflash_config.target_layer_ids == [4,16,28,40,52]' \
  "$fixture/out.json" >/dev/null \
  || fail "draft config surgery expression does not preserve non-architecture fields"

# Quality profile: same target-fidelity flags as the validated 08-16 vLLM DSpark profile.
contains "$V2_VLLM" '--dtype bfloat16'
contains "$V2_VLLM" '--tensor-parallel-size 2'
contains "$V2_VLLM" '--kv-cache-dtype auto'
contains "$V2_VLLM" '--mamba-ssm-cache-dtype float32'
contains "$V2_VLLM" '--enable-prefix-caching'
contains "$V2_VLLM" '--enable-chunked-prefill'
contains "$V2_VLLM" '--reasoning-parser qwen3'
contains "$V2_VLLM" '--tool-call-parser qwen3_coder'
contains "$V2_VLLM" 'DSARK_BLOCK_SIZE=7'
contains "$V2_VLLM" '"method\":\"dspark\"'
contains "$V2_VLLM" 'attention_backend\":\"FLASH_ATTN\"'
contains "$V2_VLLM" 'draft_sample_method\":\"probabilistic\"'
contains "$V2_VLLM" 'num_speculative_tokens\":$DSARK_BLOCK_SIZE'
if grep -Fq -- '"method\":\"mtp\"' "$V2_VLLM" || grep -Fq -- 'SPEC_METHOD' "$V2_VLLM"; then
  fail "$V2_VLLM enables the MTP spec path, which #52480 still blocks at TP>=2"
fi

# --- v2 SGLang DSpark: same pinned image, cookbook mamba formula ------------
contains "$V2_SGLANG" 'IMAGE="lmsysorg/sglang:qwen38-27b"'
contains "$V2_SGLANG" 'DIGEST="sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124"'
contains "$V2_SGLANG" 'DRAFT_HOST="/models/Qwen3.8-27B-DSpark-v2"'
contains "$V2_SGLANG" 'DRAFT_CONTAINER="/models/RadixArk/Qwen3.8-27B-DSpark-v2"'
contains "$V2_SGLANG" 'NAME="qwen38-27b-bf16-dspark-sglang-v2"'
contains "$V2_SGLANG" 'ENVFILE="$CONFIG_DIR/sglang-dspark-v2.env"'
# 08-17 cookbook formula (PR #35064): concurrency x S, S only, D excluded.
contains "$V2_SGLANG" 'MAMBA_STATE_SLOTS="${MAMBA_STATE_SLOTS:-5}"'
contains "$V2_SGLANG" 'MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * MAMBA_STATE_SLOTS))}"'
if grep -Fq 'MAX_RUNNING_REQUESTS * (5 + DSPARK_GAMMA + 1)' "$V2_SGLANG"; then
  fail "$V2_SGLANG still folds the speculative verify window into the mamba pin"
fi
# Everything else stays at the validated 08-16 settings.
contains "$V2_SGLANG" 'MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"'
contains "$V2_SGLANG" 'CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"'
contains "$V2_SGLANG" 'MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"'
contains "$V2_SGLANG" '-e SGLANG_RAGGED_VERIFY_MODE=static'
contains "$V2_SGLANG" '--kv-cache-dtype bfloat16'
contains "$V2_SGLANG" '--mamba-ssm-dtype float32'
contains "$V2_SGLANG" '--mamba-radix-cache-strategy extra_buffer'
contains "$V2_SGLANG" '--max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE"'
contains "$V2_SGLANG" '--attention-backend flashinfer'
contains "$V2_SGLANG" '--cuda-graph-max-bs-decode "$MAX_RUNNING_REQUESTS"'
contains "$V2_SGLANG" '--dtype bfloat16'
contains "$V2_SGLANG" '--tp-size 2'
contains "$V2_SGLANG" '--trust-remote-code'
contains "$V2_SGLANG" '--enable-multimodal'
contains "$V2_SGLANG" '--enable-metrics'
contains "$V2_SGLANG" '--speculative-algorithm DSPARK'
contains "$V2_SGLANG" '--speculative-draft-model-path "$DRAFT_CONTAINER"'
contains "$V2_SGLANG" '--speculative-dspark-block-size "$DSPARK_GAMMA"'
contains "$V2_SGLANG" 'DSPARK_GAMMA="${DSPARK_GAMMA:-7}"'
contains "$V2_SGLANG" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$V2_SGLANG" 'inference_prepare_api_key "${SGLANG_API_KEY:-${VLLM_API_KEY:-}}"'
contains "$V2_SGLANG" 'inference_write_private_file "$ENVFILE" <<EOF'
contains "$V2_SGLANG" 'ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"'
contains "$V2_SGLANG" 'nvidia-smi --query-gpu=index,power.limit'
contains "$V2_SGLANG" 'MAX_GPU_POWER_LIMIT'
contains "$V2_SGLANG" 'docker run -d --init'
contains "$V2_SGLANG" '--gpus all'
contains "$V2_SGLANG" '--ipc=host'
contains "$V2_SGLANG" '--network host'
contains "$V2_SGLANG" '-e CUDA_VISIBLE_DEVICES="$GPU_ORDER"'
contains "$V2_SGLANG" '--port 8000'
if grep -Eq '^[[:space:]]*-e SGLANG_API_KEY=' "$V2_SGLANG"; then
  fail "$V2_SGLANG exposes SGLANG_API_KEY in Docker command arguments"
fi

# --- 08-16 profiles remain intact with their original pins -------------------
contains "$OLD_DL" 'REV="923ed3a8572615643f0137e424e4ce4edd7f1cda"'
contains "$OLD_DL" 'DEST="/models/Qwen3.8-27B-DSpark"'
contains "$OLD_SGLANG" 'NAME="qwen38-27b-bf16-dspark-sglang"'
contains "$OLD_SGLANG" 'MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * (5 + DSPARK_GAMMA + 1)))}"'
contains "$OLD_VLLM" 'IMAGE="vllm/vllm-openai:nightly-ac7509e2b1db40fec2f03dde1ed4e9dfdc2338c9"'
contains "$OLD_VLLM" 'NAME="qwen38-27b-bf16-dspark-vllm"'

# --- the new runbook documents both v2 profiles and the mamba rationale -----
contains "$DOC" 'Experimental Qwen3.8-27B DSpark on SGLang (v2)'
contains "$DOC" 'Experimental Qwen3.8-27B DSpark on vLLM (v2)'
contains "$DOC" 'nightly-aa9903490c616dc6871e5acc62cec7bb1e5e9434'
contains "$DOC" '85ef153be924f17ce4bf62726954eeaa4a73e854'
contains "$DOC" 'MAMBA_STATE_SLOTS'

printf 'PASS: Qwen3.8 DSpark v2 profile contract is internally consistent\n'
