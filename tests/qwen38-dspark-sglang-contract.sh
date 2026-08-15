#!/usr/bin/env bash
# Static contract test for the experimental Qwen3.8-27B BF16 + DSpark SGLang profile.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/run-qwen38-27b-bf16-dspark-sglang.sh"
DOWNLOAD_TARGET="$ROOT/scripts/download-qwen38-27b.sh"
DOWNLOAD_DRAFT="$ROOT/scripts/download-qwen38-27b-dspark.sh"
ENTRYPOINT="$ROOT/scripts/sglang-secure-entrypoint.py"
DOC="$ROOT/docs/new-desktop-install.md"
IMAGE="lmsysorg/sglang:qwen38-27b"
DIGEST="sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124"
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

[[ -x "$RUN" ]] || fail "$RUN is not executable"
[[ -x "$DOWNLOAD_TARGET" ]] || fail "$DOWNLOAD_TARGET is not executable"
[[ -x "$DOWNLOAD_DRAFT" ]] || fail "$DOWNLOAD_DRAFT is not executable"
[[ -r "$ENTRYPOINT" ]] || fail "$ENTRYPOINT is not readable"
bash -n "$RUN"
bash -n "$DOWNLOAD_TARGET"
bash -n "$DOWNLOAD_DRAFT"

contains "$RUN" "IMAGE=\"$IMAGE\""
contains "$RUN" "DIGEST=\"$DIGEST\""
contains "$RUN" 'NAME="qwen38-27b-bf16-dspark-sglang"'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" "printf 'SGLANG_API_KEY=%s\\n'"
contains "$RUN" 'install -m 600 "$HOME/.config/ds4-flash/api-key" "$KEYFILE"'
contains "$RUN" '-e SGLANG_RAGGED_VERIFY_MODE=static'
if grep -Eq -- '^[[:space:]]*--api-key([=[:space:]]|$)' "$RUN"; then
  fail "$RUN exposes the SGLang API key through Docker command arguments"
fi
contains "$ENTRYPOINT" 'os.environ.pop("SGLANG_API_KEY", "")'
contains "$ENTRYPOINT" 'prepare_server_args([*cli_args, "--api-key", api_key])'
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--tp-size 2'
contains "$RUN" '--kv-cache-dtype bfloat16'
contains "$RUN" '--mamba-ssm-dtype float32'
contains "$RUN" '--mamba-radix-cache-strategy extra_buffer'
contains "$RUN" 'MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"'
contains "$RUN" 'CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"'
contains "$RUN" 'CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"'
contains "$RUN" 'MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"'
contains "$RUN" 'DSPARK_GAMMA="${DSPARK_GAMMA:-7}"'
contains "$RUN" 'MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * (5 + DSPARK_GAMMA + 1)))}"'
contains "$RUN" '--language-model-only'
contains "$RUN" '--attention-backend flashinfer'
contains "$RUN" '--speculative-algorithm DSPARK'
contains "$RUN" '--speculative-draft-model-quantization unquant'
contains "$RUN" '--reasoning-parser qwen3'
contains "$RUN" '--tool-call-parser qwen3_coder'
contains "$RUN" '--sampling-defaults model'
contains "$RUN" '--enable-metrics'
if grep -Fq -- '--chat-template ' "$RUN"; then
  fail "$RUN overrides the checkpoint-native Qwen3.8 chat template"
fi
contains "$DOWNLOAD_TARGET" "REV=\"$TARGET_REV\""
contains "$DOWNLOAD_DRAFT" "REV=\"$DRAFT_REV\""
contains "$DOC" 'Experimental Qwen3.8-27B DSpark on SGLang'
contains "$DOC" "$IMAGE"
contains "$DOC" "$DIGEST"
contains "$DOC" "$DRAFT_REV"

printf 'PASS: Qwen3.8 DSpark SGLang contract is internally consistent\n'
