#!/usr/bin/env bash
# Launch DeepSeek-V4-Flash-0731 (Infernal Invocation r18, probabilistic K5) on `desktop`.
#
# TP2/DCP1, B12X W4A8, fixed probabilistic K5, FP8 compressed MLA KV, and FULL
# target/draft/context-KV CUDA graphs — the release's qualified two-card profile.
# OpenAI-compatible endpoint on :8000. Go headless first
# (`sudo systemctl stop display-manager`) so X does not retain GPU memory.
#
# The checkpoint must already be on disk; run
# scripts/inference/deepseek/download-ds4-flash.sh first.
# Full rationale: docs/runbooks/new-desktop-install.md — "Running DeepSeek-V4-Flash
# (Infernal Invocation r18, K5)".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"

IMG="voipmonitor/vllm:infernal-invocation-vllmf0fa1ce-b12x75787c7-fi1ac6942-cu133-torch213-20260818-r18@sha256:414ec7d0d28358cfd8af0697f330f5c8acbb80e4dc4e5ba69c9fd5b5855ea804"
MODEL_HOST="/models/DeepSeek-V4-Flash-0731"
CACHE_HOST="/models/vllm-cache/infernal-invocation-r18"
NAME="ds4-infernal-invocation-cu133-r18"

# This box's eight-agent, checkpoint-native scheduler envelope. Override per launch.
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-1048576}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.975}"

# Native vLLM offload and LMCache are independent, disabled-by-default profiles.
KV_OFFLOADING_SIZE="${KV_OFFLOADING_SIZE:-0}"
NATIVE_L2_GB="${NATIVE_L2_GB:-0}"
NATIVE_L2_PATH="${NATIVE_L2_PATH:-/native-l2/deepseek-v4-flash-0731/8000}"
LMCACHE_MODE="${LMCACHE_MODE:-off}"
LMCACHE_L1_GB="${LMCACHE_L1_GB:-24}"
LMCACHE_L2_GB="${LMCACHE_L2_GB:-512}"
LMCACHE_L2_PATH="${LMCACHE_L2_PATH:-/cache/lmcache/8000}"

if [ "$LMCACHE_MODE" != off ] \
  && { [ "$KV_OFFLOADING_SIZE" != 0 ] || [ "$NATIVE_L2_GB" != 0 ]; }; then
  echo "error: native vLLM KV offload and LMCache cannot be enabled together" >&2
  exit 2
fi

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: checkpoint not found at $MODEL_HOST — run scripts/inference/deepseek/download-ds4-flash.sh first" >&2
  exit 1
fi

# Resolve the human operator even under sudo. Exclusive :8000 profiles and the
# concurrent Muse endpoint share one credential.
inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_DS4_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/ds4-flash/container.env"

# Docker CLI arguments are visible through /proc; keep the secret in a private env file.
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

sudo mkdir -p "$CACHE_HOST/tmp" /models/native-l2

# Remove prior release containers during an in-place upgrade; host networking otherwise
# leaves their :8000 listener in the way.
docker rm -f ds4-0731-r31 2>/dev/null || true
docker rm -f ds4-0731-r33 2>/dev/null || true
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
  --entrypoint /usr/local/bin/lmcache-mp-wrapper.sh \
  -v "$MODEL_HOST":/models/deepseek-ai/DeepSeek-V4-Flash-0731:ro \
  -v "$CACHE_HOST":/cache \
  -v "$CACHE_HOST/tmp":/container-tmp \
  -v /models/native-l2:/native-l2 \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e GLOO_SOCKET_IFNAME=lo \
  -e NCCL_SOCKET_IFNAME=lo \
  -e OMP_NUM_THREADS=2 \
  -e SERVED_MODEL_NAME=deepseek-v4-flash \
  -e MODEL_PATH=/models/deepseek-ai/DeepSeek-V4-Flash-0731 \
  -e PORT=8000 \
  -e MODE=dspark -e DSPARK_DEPTH_MODE=fixed -e DSPARK_TOKENS=5 \
  -e DSPARK_CAPACITY_ACTIVATION_BATCH_SIZE=0 \
  -e DRAFT_SAMPLE_METHOD=probabilistic \
  -e BACKEND=b12x-a8 -e TP_SIZE=2 -e DCP_SIZE=1 \
  -e ALLREDUCE_MODE=auto \
  -e MAX_NUM_SEQS="$MAX_NUM_SEQS" \
  -e MAX_MODEL_LEN="$MAX_MODEL_LEN" \
  -e MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS" \
  -e GRAPH=auto \
  -e GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION" \
  -e LOAD_FORMAT=instanttensor -e INSTANTTENSOR_BACKEND=BUFFERED \
  -e PYTHONHASHSEED=0 \
  -e KV_OFFLOADING_SIZE="$KV_OFFLOADING_SIZE" \
  -e NATIVE_L2_GB="$NATIVE_L2_GB" \
  -e NATIVE_L2_PATH="$NATIVE_L2_PATH" \
  -e LMCACHE_MODE="$LMCACHE_MODE" \
  -e LMCACHE_L1_GB="$LMCACHE_L1_GB" \
  -e LMCACHE_L2_GB="$LMCACHE_L2_GB" \
  -e LMCACHE_L2_PATH="$LMCACHE_L2_PATH" \
  "$IMG" \
  /usr/local/bin/serve-ds4-flash.sh

echo "Started '$NAME'. First start may compile uncovered B12X/CUDA graph shapes on the persistent cache."
echo "Follow:  docker logs -f $NAME"
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
