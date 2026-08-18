#!/usr/bin/env bash
# Static contract test for the pinned Qwen3.8-27B BF16 deployment.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16.sh"
DOWNLOAD="$ROOT/scripts/inference/qwen38/download-qwen38-27b.sh"
DOC="$ROOT/docs/runbooks/new-desktop-install.md"
PI_MODELS="$ROOT/pi/models.json"
IMAGE="vllm/vllm-openai:qwen38"
DIGEST="sha256:d392f621bb3e372ecc09f0b0cb88099afe9fa05d37a0450de45eeb8c12b6787e"
MODEL_REV="1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

[[ -x "$RUN" ]] || fail "$RUN is not executable"
[[ -x "$DOWNLOAD" ]] || fail "$DOWNLOAD is not executable"
bash -n "$RUN"
bash -n "$DOWNLOAD"

contains "$RUN" "IMAGE=\"$IMAGE\""
contains "$RUN" "DIGEST=\"$DIGEST\""
contains "$RUN" 'NAME="qwen38-27b-bf16"'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$RUN" 'inference_prepare_api_key "${VLLM_API_KEY:-}"'
contains "$RUN" 'inference_write_private_file "$ENVFILE" <<EOF'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "$RUN exposes VLLM_API_KEY in process arguments"
fi
contains "$RUN" '--dtype bfloat16'
contains "$RUN" 'TP_SIZE="${TP_SIZE:-2}"'
contains "$RUN" '--tensor-parallel-size "$TP_SIZE"'
contains "$RUN" '--kv-cache-dtype auto'
contains "$RUN" '--mamba-ssm-cache-dtype float32'
if grep -Fq -- '--language-model-only' "$RUN"; then
  fail "$RUN strips the vision tower; the Qwen3.8 profile serves the full multimodal checkpoint"
fi
contains "$RUN" '--reasoning-parser qwen3'
contains "$RUN" '--tool-call-parser qwen3_coder'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"'
# MTP speculative decoding is an opt-in, off by default, and refused at TP>=2
# while vLLM #52480 (qwen3_5 MTP drafter weight-load crash) is open. The refusal
# path runs before any filesystem access, so it is safe to execute here.
contains "$RUN" 'SPEC_MTP="${SPEC_MTP:-0}"'
contains "$RUN" 'SPEC_TOKENS="${SPEC_TOKENS:-3}"'
mtp_refusal=""
mtp_status=0
mtp_refusal="$(SPEC_MTP=1 TP_SIZE=2 bash "$RUN" 2>&1)" || mtp_status=$?
if [[ $mtp_status -ne 2 || "$mtp_refusal" != *"SPEC_MTP=1 is refused at TP_SIZE>=2"* ]]; then
  fail "$RUN must refuse SPEC_MTP=1 at TP_SIZE>=2 with exit 2 while vLLM #52480 is open"
fi
if grep -Fq -- '--chat-template' "$RUN"; then
  fail "$RUN overrides the checkpoint-native Qwen3.8 chat template"
fi
contains "$DOWNLOAD" "REV=\"$MODEL_REV\""
contains "$DOWNLOAD" 'export HF_HUB_DISABLE_XET=1'
if grep -Fq 'HF_XET_HIGH_PERFORMANCE' "$DOWNLOAD"; then
  fail "$DOWNLOAD re-enables the Xet backend that hangs on this workstation"
fi
contains "$DOC" 'Running Qwen3.8-27B BF16 on vLLM'
contains "$DOC" "$IMAGE"
contains "$DOC" "$DIGEST"
contains "$DOC" "$MODEL_REV"

jq -e '
  .providers."desktop-vllm" as $provider |
  ($provider.apiKey | contains("~/.config/qwen38/api-key")) and
  ($provider.models | any(
    .id == "deepseek-v4-flash" and .compat.thinkingFormat == "deepseek"
  )) and
  ($provider.models | any(
    .id == "qwen3.8-27b" and
    .defaultThinkingLevel == "xhigh" and
    .contextWindow == 262144 and
    .input == ["text", "image"] and
    .thinkingLevelMap == {
      "off": null,
      "minimal": null,
      "low": "low",
      "medium": null,
      "high": null,
      "xhigh": "xhigh",
      "max": null
    } and
    .compat.supportsDeveloperRole == false and
    .compat.thinkingFormat == "chat-template" and
    .compat.chatTemplateKwargs == {
      "enable_thinking": {"$var": "thinking.enabled"},
      "preserve_thinking": true,
      "reasoning_effort": {"$var": "thinking.effort", "omitWhenOff": true}
    }
  ))
' "$PI_MODELS" >/dev/null || fail "Pi's desktop-vllm catalog does not expose the Qwen native-template contract"

printf 'PASS: Qwen3.8 BF16 release and Pi model contracts are internally consistent\n'
