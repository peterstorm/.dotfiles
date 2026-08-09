#!/usr/bin/env bash
# Launch the DeepSeek-V4-Flash server (Gilded Gnosis r31, K5) on `desktop`.
#
# TP2/DCP1, B12X W4A8, fixed probabilistic K5, FP8 DS-MLA KV — the release's own
# default profile, which is exactly this box's two-card shape. OpenAI-compatible
# endpoint on :8000. Go headless first (`sudo systemctl stop display-manager`)
# so the GPUs aren't held by X.
#
# The checkpoint must already be on disk — run scripts/download-ds4-flash.sh first.
# Full rationale: docs/new-desktop-install.md — "Running DeepSeek-V4-Flash
# (Gilded Gnosis r31, K5)".
set -euo pipefail

IMG="voipmonitor/vllm:gilded-gnosis-v20-vllmfa13d33-b12xacee6e5-fi1ac6942-cu132-20260807-r31@sha256:3230c25ff95f8678a8eeb52a463f0d3b9f96f6ad550418cc51ea12177a55b41c"
MODEL_HOST="/models/DeepSeek-V4-Flash-0731"
NAME="ds4-0731-r31"

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: checkpoint not found at $MODEL_HOST — run scripts/download-ds4-flash.sh first" >&2
  exit 1
fi

# API key: prefer $VLLM_API_KEY, else a persistent per-machine key (not committed).
KEYFILE="$HOME/.config/ds4-flash/api-key"
if [ -z "${VLLM_API_KEY:-}" ]; then
  if [ ! -f "$KEYFILE" ]; then
    mkdir -p "$(dirname "$KEYFILE")"
    head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$KEYFILE"
    chmod 600 "$KEYFILE"
  fi
  VLLM_API_KEY="$(cat "$KEYFILE")"
fi

sudo mkdir -p /models/vllm-cache/r31/tmp

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --gpus all \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  -v "$MODEL_HOST":/models/deepseek-ai/DeepSeek-V4-Flash-0731:ro \
  -v /models/vllm-cache/r31:/cache \
  -v /models/vllm-cache/r31/tmp:/container-tmp \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_API_KEY="$VLLM_API_KEY" \
  -e SERVED_MODEL_NAME=deepseek-v4-flash \
  -e MODEL_PATH=/models/deepseek-ai/DeepSeek-V4-Flash-0731 \
  -e PORT=8000 \
  -e MODE=dspark -e DSPARK_DEPTH_MODE=fixed -e DSPARK_TOKENS=5 \
  -e BACKEND=b12x-a8 -e TP_SIZE=2 -e DCP_SIZE=1 \
  -e ALLREDUCE_MODE=auto \
  -e MAX_NUM_SEQS=16 -e MAX_MODEL_LEN=131072 -e MAX_NUM_BATCHED_TOKENS=8192 \
  -e GRAPH=auto \
  -e GPU_MEMORY_UTILIZATION=0.975 \
  -e LOAD_FORMAT=instanttensor -e INSTANTTENSOR_BACKEND=BUFFERED \
  -e PYTHONHASHSEED=0 \
  -e KV_OFFLOADING_SIZE=0 \
  "$IMG" \
  /usr/local/bin/serve-ds4-flash.sh

echo "Started '$NAME'. First start compiles kernels/CUDA graphs (~15-20 min on a cold cache)."
echo "Follow:  docker logs -f $NAME"
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
