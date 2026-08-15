#!/usr/bin/env bash
# Static contract test for the pinned Qwen3.8-27B BF16 deployment.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/run-qwen38-27b-bf16.sh"
DOWNLOAD="$ROOT/scripts/download-qwen38-27b.sh"
DOC="$ROOT/docs/new-desktop-install.md"
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
contains "$RUN" "printf 'VLLM_API_KEY=%s\\n'"
contains "$RUN" 'install -m 600 "$HOME/.config/ds4-flash/api-key" "$KEYFILE"'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "$RUN exposes VLLM_API_KEY in process arguments"
fi
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--kv-cache-dtype auto'
contains "$RUN" '--mamba-ssm-cache-dtype float32'
contains "$RUN" '--language-model-only'
contains "$RUN" '--reasoning-parser qwen3'
contains "$RUN" '--tool-call-parser qwen3_coder'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"'
if grep -Fq -- '--speculative-config' "$RUN"; then
  fail "$RUN enables speculative decoding before the GDN safety fix is available"
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
    .input == ["text"] and
    .thinkingLevelMap == {
      "off": null,
      "minimal": null,
      "low": "low",
      "medium": "medium",
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
