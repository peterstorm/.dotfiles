#!/usr/bin/env bash
# Launch the experimental Qwen3.8-27B BF16 + DSpark profile with SGLang.
#
# Quality-first target: TP2 BF16 weights/KV, FP32 GDN state, native 262K
# context, eight running requests, checkpoint-native template, and the pinned
# 1.36B BF16 DSpark draft. Static verification is mandatory for this TP2 probe.
# OpenAI-compatible endpoint on :8000.
#
# Prerequisites:
#   scripts/download-qwen38-27b.sh
#   scripts/download-qwen38-27b-dspark.sh
# Full rationale: docs/new-desktop-install.md —
# "Experimental Qwen3.8-27B DSpark on SGLang".
set -euo pipefail

IMAGE="lmsysorg/sglang:qwen38-27b"
DIGEST="sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124"
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
DRAFT_HOST="/models/Qwen3.8-27B-DSpark"
DRAFT_CONTAINER="/models/RadixArk/Qwen3.8-27B-DSpark"
CACHE_HOST="/models/sglang-cache/qwen38-bf16-dspark"
ENTRYPOINT_HOST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sglang-secure-entrypoint.py"
ENTRYPOINT_CONTAINER="/opt/reclaw/sglang-secure-entrypoint.py"
NAME="qwen38-27b-bf16-dspark-sglang"

MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"
CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
DSPARK_GAMMA="${DSPARK_GAMMA:-7}"
# extra_buffer keeps five radix state slots per request; static DSpark gamma=7
# needs an eight-state verify window. The explicit pin prevents SGLang's default
# Mamba/KV ratio from silently reducing the requested concurrency.
MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * (5 + DSPARK_GAMMA + 1)))}"

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: target checkpoint not found at $MODEL_HOST — run scripts/download-qwen38-27b.sh first" >&2
  exit 1
fi
if [ ! -e "$DRAFT_HOST/config.json" ]; then
  echo "error: DSpark checkpoint not found at $DRAFT_HOST — run scripts/download-qwen38-27b-dspark.sh first" >&2
  exit 1
fi
if [ ! -f "$ENTRYPOINT_HOST" ]; then
  echo "error: secure SGLang entrypoint not found at $ENTRYPOINT_HOST" >&2
  exit 1
fi

CONFIG_DIR="$HOME/.config/qwen38"
KEYFILE="$CONFIG_DIR/api-key"
ENVFILE="$CONFIG_DIR/sglang-dspark.env"
install -m 700 -d "$CONFIG_DIR"

# Reuse the Qwen endpoint key across vLLM and SGLang. Prefer $SGLANG_API_KEY,
# then the existing $VLLM_API_KEY convention, otherwise create a machine-local key.
if [ -z "${SGLANG_API_KEY:-}" ]; then
  SGLANG_API_KEY="${VLLM_API_KEY:-}"
fi
if [ -z "$SGLANG_API_KEY" ]; then
  if [ ! -f "$KEYFILE" ]; then
    head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$KEYFILE"
    chmod 600 "$KEYFILE"
  fi
  SGLANG_API_KEY="$(cat "$KEYFILE")"
fi

# SGLang has no native API-key environment variable. A tiny Python entrypoint
# parses this value in-process so it never appears in Docker args or /proc cmdline.
printf 'SGLANG_API_KEY=%s\n' "$SGLANG_API_KEY" > "$ENVFILE"
chmod 600 "$ENVFILE"

sudo mkdir -p "$CACHE_HOST"
sudo chown "$USER:users" "$CACHE_HOST"

docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8000' | grep -q .; then
  echo "error: TCP port 8000 is already in use; stop the current model server first" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --gpus all \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST":"$MODEL_CONTAINER":ro \
  -v "$DRAFT_HOST":"$DRAFT_CONTAINER":ro \
  -v "$CACHE_HOST":/root/.cache \
  -v "$ENTRYPOINT_HOST":"$ENTRYPOINT_CONTAINER":ro \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e SGLANG_RAGGED_VERIFY_MODE=static \
  "$IMAGE@$DIGEST" \
  python3 "$ENTRYPOINT_CONTAINER" \
  --model-path "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-27b \
  --trust-remote-code \
  --dtype bfloat16 \
  --tp-size 2 \
  --context-length "$CONTEXT_LENGTH" \
  --max-running-requests "$MAX_RUNNING_REQUESTS" \
  --chunked-prefill-size "$CHUNKED_PREFILL_SIZE" \
  --mem-fraction-static "$MEM_FRACTION_STATIC" \
  --kv-cache-dtype bfloat16 \
  --mamba-ssm-dtype float32 \
  --mamba-radix-cache-strategy extra_buffer \
  --max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE" \
  --language-model-only \
  --attention-backend flashinfer \
  --cuda-graph-max-bs-decode "$MAX_RUNNING_REQUESTS" \
  --speculative-algorithm DSPARK \
  --speculative-draft-model-path "$DRAFT_CONTAINER" \
  --speculative-draft-model-quantization unquant \
  --speculative-dspark-block-size "$DSPARK_GAMMA" \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --sampling-defaults model \
  --enable-cache-report \
  --enable-metrics \
  --host 0.0.0.0 \
  --port 8000

echo "Started '$NAME'. This is an experimental profile; first start compiles kernels and CUDA graphs."
echo "Follow:  docker logs -f $NAME"
echo "Health:  KEY=\$(cat $KEYFILE); curl -fsS -H \"Authorization: Bearer \$KEY\" http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
echo "Compare acceptance/throughput in logs before promoting it over the no-spec BF16 baseline."
