#!/usr/bin/env bash
# Launch the DeepSeek-V4-Flash server (Gilded Gnosis r33, K5) on `desktop`.
#
# TP2/DCP1, B12X W4A8, fixed probabilistic K5, FP8 DS-MLA KV — the release's own
# default profile, which is exactly this box's two-card shape. OpenAI-compatible
# endpoint on :8000. Go headless first (`sudo systemctl stop display-manager`)
# so the GPUs aren't held by X.
#
# The checkpoint must already be on disk — run scripts/download-ds4-flash.sh first.
# Full rationale: docs/new-desktop-install.md — "Running DeepSeek-V4-Flash
# (Gilded Gnosis r33, K5)".
set -euo pipefail

IMG="voipmonitor/vllm:gilded-gnosis-v20-vllmfa13d33-b12x06db0f4-fi1ac6942-cu132-20260809-r33@sha256:fdde59fed7f9fc12f9fd5ef1b3b3ea8d5097bf10ebad54b348497102c3a83f82"
MODEL_HOST="/models/DeepSeek-V4-Flash-0731"
NAME="ds4-0731-r33"

# Capacity/concurrency knobs. Defaults remain the validated upstream profile; override
# them per launch without editing this file, e.g. MAX_NUM_SEQS=8 MAX_MODEL_LEN=auto.
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.975}"
KV_OFFLOADING_SIZE="${KV_OFFLOADING_SIZE:-0}"

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: checkpoint not found at $MODEL_HOST — run scripts/download-ds4-flash.sh first" >&2
  exit 1
fi

# API key: prefer $VLLM_API_KEY, else a persistent per-machine key (not committed).
KEYFILE="$HOME/.config/ds4-flash/api-key"
ENVFILE="$HOME/.config/ds4-flash/container.env"
if [ -z "${VLLM_API_KEY:-}" ]; then
  if [ ! -f "$KEYFILE" ]; then
    mkdir -p "$(dirname "$KEYFILE")"
    head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$KEYFILE"
    chmod 600 "$KEYFILE"
  fi
  VLLM_API_KEY="$(cat "$KEYFILE")"
fi

# Docker CLI arguments are visible through /proc. Keep the secret out of `ps` by
# passing it through a private env file instead of `-e VLLM_API_KEY=value`.
printf 'VLLM_API_KEY=%s\n' "$VLLM_API_KEY" > "$ENVFILE"
chmod 600 "$ENVFILE"

if [ ! -d /models/vllm-cache/r33/tmp ]; then
  sudo mkdir -p /models/vllm-cache/r33/tmp
fi

# Remove the previous release container as part of an in-place upgrade; otherwise its
# host-network listener can keep port 8000 occupied.
docker rm -f ds4-0731-r31 2>/dev/null || true
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
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST":/models/deepseek-ai/DeepSeek-V4-Flash-0731:ro \
  -v /models/vllm-cache/r33:/cache \
  -v /models/vllm-cache/r33/tmp:/container-tmp \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e SERVED_MODEL_NAME=deepseek-v4-flash \
  -e MODEL_PATH=/models/deepseek-ai/DeepSeek-V4-Flash-0731 \
  -e PORT=8000 \
  -e MODE=dspark -e DSPARK_DEPTH_MODE=fixed -e DSPARK_TOKENS=5 \
  -e BACKEND=b12x-a8 -e TP_SIZE=2 -e DCP_SIZE=1 \
  -e ALLREDUCE_MODE=auto \
  -e B12X_PCIE_TP2_REMOTE_PUSH=0 \
  -e B12X_PCIE_TP4_REMOTE_PUSH=0 \
  -e B12X_PCIE_TP8_OWNER_REDUCE=1 \
  -e MAX_NUM_SEQS="$MAX_NUM_SEQS" \
  -e MAX_MODEL_LEN="$MAX_MODEL_LEN" \
  -e MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS" \
  -e GRAPH=auto \
  -e GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION" \
  -e LOAD_FORMAT=instanttensor -e INSTANTTENSOR_BACKEND=BUFFERED \
  -e PYTHONHASHSEED=0 \
  -e KV_OFFLOADING_SIZE="$KV_OFFLOADING_SIZE" \
  "$IMG" \
  /usr/local/bin/serve-ds4-flash.sh

echo "Started '$NAME'. First start compiles kernels/CUDA graphs (~15-20 min on a cold cache)."
echo "Follow:  docker logs -f $NAME"
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
