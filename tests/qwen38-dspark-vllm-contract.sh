#!/usr/bin/env bash
# Static contract test for the experimental Qwen3.8-27B BF16 + DSpark vLLM profile.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/run-qwen38-27b-bf16-dspark-vllm.sh"
DOWNLOAD_TARGET="$ROOT/scripts/download-qwen38-27b.sh"
DOWNLOAD_DRAFT="$ROOT/scripts/download-qwen38-27b-dspark.sh"
DOC="$ROOT/docs/new-desktop-install.md"
IMAGE="vllm/vllm-openai:nightly-ac7509e2b1db40fec2f03dde1ed4e9dfdc2338c9"
DIGEST="sha256:ecc6a14f77a9c788d78d5eee2eec371246567ab40989b58ec1d73a691c7cd54e"
TARGET_REV="1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"
DRAFT_REV="923ed3a8572615643f0137e424e4ce4edd7f1cda"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

command -v jq >/dev/null 2>&1 || fail "jq is required for the surgery assertion"

[[ -x "$RUN" ]] || fail "$RUN is not executable"
[[ -x "$DOWNLOAD_TARGET" ]] || fail "$DOWNLOAD_TARGET is not executable"
[[ -x "$DOWNLOAD_DRAFT" ]] || fail "$DOWNLOAD_DRAFT is not executable"
bash -n "$RUN"
bash -n "$DOWNLOAD_TARGET"
bash -n "$DOWNLOAD_DRAFT"

# Image pin: upstream commit ac7509e2 (2026-08-14) — verifiably carries the DSpark
# PRs (#46995/#47093), the #43559 hybrid-GDN prefix-cache fix stack, and #51812.
contains "$RUN" "IMAGE=\"$IMAGE\""
contains "$RUN" "DIGEST=\"$DIGEST\""
contains "$RUN" 'NAME="qwen38-27b-bf16-dspark-vllm"'

# Key handling: env-file only, never Docker command arguments.
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" "printf 'VLLM_API_KEY=%s\\n'"
contains "$RUN" 'install -m 600 "$HOME/.config/ds4-flash/api-key" "$KEYFILE"'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "$RUN exposes VLLM_API_KEY in process arguments"
fi

# Draft config surgery: rewrite architectures on an ISOLATED copy so the SGLang
# profile's checkpoint stays byte-identical, and only rerun when needed.
contains "$RUN" 'DRAFT_HOST="/models/Qwen3.8-27B-DSpark"'
contains "$RUN" 'DRAFT_VLLM_HOST="/models/Qwen3.8-27B-DSpark-vllm"'
contains "$RUN" 'cp -a "$DRAFT_HOST" "${DRAFT_VLLM_HOST}.tmp"'
contains "$RUN" "jq -e '.architectures == [\"Qwen3DSparkModel\"]'"
if grep -Eq -- 'jq [^|]*"\$DRAFT_HOST' "$RUN"; then
  fail "$RUN rewrites the SGLang draft copy in place instead of an isolated vLLM copy"
fi

# The surgery expression itself: rewrite exactly one field, preserve the rest.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/config.json" <<'JSON'
{"architectures":["DSparkDraftModel"],"block_size":7,"dflash_config":{"target_layer_ids":[4,16,28,40,52]}}
JSON
jq '(.architectures = ["Qwen3DSparkModel"])' "$fixture/config.json" > "$fixture/out.json"
jq -e '.architectures == ["Qwen3DSparkModel"] and .block_size == 7 and .dflash_config.target_layer_ids == [4,16,28,40,52]' \
  "$fixture/out.json" >/dev/null \
  || fail "draft config surgery expression does not preserve non-architecture fields"

# Quality profile: same target-fidelity flags as the vLLM BF16 baseline.
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--kv-cache-dtype auto'
contains "$RUN" '--mamba-ssm-cache-dtype float32'
if grep -Fq -- '--language-model-only' "$RUN"; then
  fail "$RUN strips the vision tower; the Qwen3.8 profile serves the full multimodal checkpoint"
fi
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--enable-chunked-prefill'
contains "$RUN" '--reasoning-parser qwen3'
contains "$RUN" '--tool-call-parser qwen3_coder'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"'
if grep -Fq -- '--chat-template ' "$RUN"; then
  fail "$RUN overrides the checkpoint-native Qwen3.8 chat template"
fi

# Speculative config: DSpark method, block size 7 (the draft's trained size),
# probabilistic draft sampling.
contains "$RUN" 'DSARK_BLOCK_SIZE=7'
contains "$RUN" '"method\":\"dspark\"'
contains "$RUN" 'attention_backend\":\"FLASH_ATTN\"'
contains "$RUN" 'draft_sample_method\":\"probabilistic\"'
contains "$RUN" 'num_speculative_tokens\":$DSARK_BLOCK_SIZE'

contains "$DOWNLOAD_TARGET" "REV=\"$TARGET_REV\""
contains "$DOWNLOAD_DRAFT" "REV=\"$DRAFT_REV\""
contains "$DOWNLOAD_DRAFT" 'export HF_HUB_DISABLE_XET=1'
if grep -Fq 'HF_XET_HIGH_PERFORMANCE' "$DOWNLOAD_DRAFT"; then
  fail "$DOWNLOAD_DRAFT re-enables the Xet backend that hangs on this workstation"
fi
contains "$DOC" 'Experimental Qwen3.8-27B DSpark on vLLM'

printf 'PASS: Qwen3.8 DSpark-on-vLLM experimental profile contract is internally consistent\n'
