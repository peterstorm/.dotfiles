#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016 # Runtime-relative source and literal source probes.
# Contract for Blackfrost's abliterated Qwen3.8-27B BF16 on the pinned TP1 vLLM profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD="$ROOT/scripts/inference/qwen38/download-qwen38-27b-blackfrost-abliterated-bf16.sh"
MANIFEST="$ROOT/scripts/inference/qwen38/qwen38-27b-blackfrost-abliterated-bf16-v1.manifest"
RUNTIME="$ROOT/scripts/inference/qwen38/run-qwen38-27b-blackfrost-abliterated-bf16-vllm.sh"
PI_MODELS="$ROOT/pi/models.json"
TARGET_REV="9d85770e5eb602322b4bceef55beda357e0bd0ca"
MANIFEST_SHA256="5fb7e9d4daf9c9be6616a5026b704c34de31cb046a2ea6f72bf65c8007899a6c"
IMAGE_DIGEST="sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674"
DRAFT_REV="dedf8df68adfb1afeaf7b7480c0a0243108177b4"
TOTAL_BYTES=55586061398

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for file in "$DOWNLOAD" "$RUNTIME"; do
  [ -r "$file" ] || fail "$file is not readable"
  [ -x "$file" ] || fail "$file is not executable"
  bash -n "$file" || fail "$file is not valid bash"
done
[ -r "$MANIFEST" ] || fail "$MANIFEST is not readable"

# The manifest is the download's root of trust, so its own identity is pinned.
if [ "$(sha256sum "$MANIFEST" | cut -d' ' -f1)" != "$MANIFEST_SHA256" ]; then
  fail "manifest digest drifted from the pinned identity"
fi
contains "$DOWNLOAD" "MANIFEST_SHA256=\"$MANIFEST_SHA256\""
contains "$DOWNLOAD" "REV=\"$TARGET_REV\""
contains "$DOWNLOAD" 'REPO="Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16"'

# Every artifact carries a 64-hex digest, a positive size, and a relative path.
awk -F'\t' '
  NF != 3 { print "malformed record: " $0 > "/dev/stderr"; exit 1 }
  $1 !~ /^[0-9a-f]{64}$/ { print "bad digest: " $0 > "/dev/stderr"; exit 1 }
  $2 !~ /^[1-9][0-9]*$/ { print "bad size: " $0 > "/dev/stderr"; exit 1 }
  $3 ~ /^\// || $3 ~ /\.\./ { print "unsafe path: " $0 > "/dev/stderr"; exit 1 }
  { total += $2 }
  END { print total }
' "$MANIFEST" > /tmp/qwen-blackfrost-manifest-total || fail "manifest records are malformed"
if [ "$(cat /tmp/qwen-blackfrost-manifest-total)" != "$TOTAL_BYTES" ]; then
  fail "manifest total size drifted from $TOTAL_BYTES bytes"
fi
rm -f /tmp/qwen-blackfrost-manifest-total
if [ "$(wc -l < "$MANIFEST")" -ne 31 ]; then
  fail "manifest does not describe all 31 checkpoint artifacts"
fi

# hf-xet 1.6.0 stalls on this workstation; the fallback must stay in place.
contains "$DOWNLOAD" 'HF_HUB_DISABLE_XET=1'
if grep -Fq -- 'hf_xet' "$DOWNLOAD"; then
  fail "downloader re-enables the Xet transfer that stalls on this workstation"
fi

# Structural divergence from the qualified 27B contract must be refused.
contains "$DOWNLOAD" 'Qwen3_5ForConditionalGeneration'
contains "$DOWNLOAD" 'BF16 master must not carry a quantization config'
contains "$DOWNLOAD" '262_144'
contains "$DOWNLOAD" '55_562_855_904'

contains "$RUNTIME" "IMAGE_DIGEST=\"$IMAGE_DIGEST\""
contains "$RUNTIME" "MODEL_PIN=\"Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16@$TARGET_REV\""
contains "$RUNTIME" "DRAFT_PIN=\"incoai/Qwen3.8-27B-DFlash2@$DRAFT_REV\""
contains "$RUNTIME" 'SERVED_MODEL="qwen3.8-27b-blackfrost-abliterated"'
contains "$RUNTIME" 'SPECULATION="${QWEN_BLACKFROST_SPECULATION:-target-only}"'
contains "$RUNTIME" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUNTIME" 'error: MAX_MODEL_LEN exceeds the checkpoint-native 262144-token contract'
contains "$RUNTIME" '--reasoning-parser qwen3'
contains "$RUNTIME" '--tool-call-parser qwen3_coder'
contains "$RUNTIME" '--dtype bfloat16'
contains "$RUNTIME" '--tensor-parallel-size 1'
contains "$RUNTIME" '--mamba-ssm-cache-dtype float32'
contains "$RUNTIME" '--attention-backend flashinfer'
# LAN-reachable like every other profile, so Pi and Prometheus can both reach it.
contains "$RUNTIME" '--host 0.0.0.0'
contains "$RUNTIME" '--env-file "$ENVFILE"'
contains "$RUNTIME" 'inference_prepare_api_key'
contains "$RUNTIME" 'is not the unquantized Qwen3.8-27B architecture this profile serves'
contains "$RUNTIME" 'lacks the pinned revision marker'

# Credentials must never reach the process table.
if grep -Eq -- '^[[:space:]]*--api-key([=[:space:]]|$)' "$RUNTIME"; then
  fail "runtime exposes the API key through process arguments"
fi

jq -e '
  .providers."desktop-vllm".models | any(
    .id == "qwen3.8-27b-blackfrost-abliterated" and
    .reasoning == true and
    .defaultThinkingLevel == "xhigh" and
    .input == ["text", "image"] and
    .contextWindow == 262144 and
    .maxTokens == 32768 and
    .compat.supportsDeveloperRole == false and
    .compat.requiresReasoningContentOnAssistantMessages == true and
    .compat.thinkingFormat == "chat-template" and
    .compat.chatTemplateKwargs.enable_thinking == {"$var": "thinking.enabled"} and
    .compat.chatTemplateKwargs.preserve_thinking == true
  )
' "$PI_MODELS" >/dev/null ||
  fail "Pi's desktop-vllm catalog does not expose the Blackfrost abliterated Qwen model"

printf 'PASS: Blackfrost abliterated Qwen3.8-27B BF16 profile is pinned, LAN-served, and credential-safe\n'
