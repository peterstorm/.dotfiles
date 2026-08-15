#!/usr/bin/env bash
# Launch Qwen3.8-27B BF16 on the desktop's two RTX PRO 6000 Blackwell GPUs.
#
# Quality-first profile: TP2, BF16 weights/attention KV, model-declared FP32
# recurrent state, native 262K context, eight scheduler slots, native template, and
# no speculative decoding. OpenAI-compatible endpoint on :8000.
#
# The checkpoint must already be on disk — run scripts/download-qwen38-27b.sh.
# Full rationale: docs/new-desktop-install.md — "Running Qwen3.8-27B BF16 on vLLM".
set -euo pipefail

IMAGE="vllm/vllm-openai:qwen38"
DIGEST="sha256:d392f621bb3e372ecc09f0b0cb88099afe9fa05d37a0450de45eeb8c12b6787e"
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
CACHE_HOST="/models/vllm-cache/qwen38-bf16"
NAME="qwen38-27b-bf16"

MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: checkpoint not found at $MODEL_HOST — run scripts/download-qwen38-27b.sh first" >&2
  exit 1
fi

CONFIG_DIR="$HOME/.config/qwen38"
KEYFILE="$CONFIG_DIR/api-key"
ENVFILE="$CONFIG_DIR/container.env"
install -m 700 -d "$CONFIG_DIR"

# API key: prefer $VLLM_API_KEY, otherwise reuse the workstation's existing
# DeepSeek credential before generating one. Both models share :8000, so one
# stable credential lets Pi switch models without changing provider auth.
if [ -z "${VLLM_API_KEY:-}" ]; then
  if [ ! -f "$KEYFILE" ]; then
    if [ -r "$HOME/.config/ds4-flash/api-key" ]; then
      install -m 600 "$HOME/.config/ds4-flash/api-key" "$KEYFILE"
    else
      head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$KEYFILE"
      chmod 600 "$KEYFILE"
    fi
  fi
  VLLM_API_KEY="$(cat "$KEYFILE")"
fi

# Keep the key out of Docker's command arguments and the host process list.
printf 'VLLM_API_KEY=%s\n' "$VLLM_API_KEY" > "$ENVFILE"
chmod 600 "$ENVFILE"

sudo mkdir -p "$CACHE_HOST"
sudo chown "$USER:users" "$CACHE_HOST"

# Make relaunch idempotent, then reject a different server already owning :8000.
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
  -v "$CACHE_HOST":/root/.cache \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMAGE@$DIGEST" \
  "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-27b \
  --dtype bfloat16 \
  --tensor-parallel-size 2 \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --kv-cache-dtype auto \
  --mamba-ssm-cache-dtype float32 \
  --language-model-only \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"min_p":0.0,"presence_penalty":0.0,"repetition_penalty":1.0}' \
  --host 0.0.0.0 \
  --port 8000

echo "Started '$NAME'. First start downloads/compiles runtime kernels and may take several minutes."
echo "Follow:  docker logs -f $NAME"
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
