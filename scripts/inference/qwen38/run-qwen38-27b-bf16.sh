#!/usr/bin/env bash
# Launch Qwen3.8-27B BF16 on one or both RTX PRO 6000 Blackwell GPUs.
#
# The standalone default remains quality-first TP2. The concurrent Muse profile
# sets TP_SIZE=1 GPU_DEVICES=1, keeps BF16 weights/KV and FP32 recurrent state,
# and leaves physical GPU0 for Muse. OpenAI-compatible endpoint on :8000.
#
# MTP speculative decoding (the in-checkpoint one-layer MTP head) is available as an
# opt-in: TP_SIZE=1 SPEC_MTP=1 bash scripts/inference/qwen38/run-qwen38-27b-bf16.sh.
# It is refused at TP>=2 while vLLM issue #52480 (qwen3_5 MTP drafter weight-load crash)
# is open, and the image must demonstrably carry vLLM #51812 + #51674. Full rationale
# and gate: docs/runbooks/new-desktop-install.md, "Why MTP is off".
#
# The checkpoint must already be on disk —
# run scripts/inference/qwen38/download-qwen38-27b.sh.
# Full rationale: docs/runbooks/new-desktop-install.md — "Running Qwen3.8-27B BF16 on vLLM".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"

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
TP_SIZE="${TP_SIZE:-2}"
GPU_DEVICES="${GPU_DEVICES:-}"
PORT="${PORT:-8000}"
SPEC_MTP="${SPEC_MTP:-0}"
SPEC_TOKENS="${SPEC_TOKENS:-3}"
case "$TP_SIZE" in
  1|2) ;;
  *) echo "error: TP_SIZE must be 1 or 2 (got: $TP_SIZE)" >&2; exit 2 ;;
esac
if [ -z "$GPU_DEVICES" ]; then
  if [ "$TP_SIZE" = "1" ]; then
    GPU_DEVICES="0"
  else
    GPU_DEVICES="1,0"
  fi
fi
case "$TP_SIZE:$GPU_DEVICES" in
  1:0|1:1) CONTAINER_CUDA_VISIBLE_DEVICES="0" ;;
  2:0,1|2:1,0) CONTAINER_CUDA_VISIBLE_DEVICES="0,1" ;;
  *)
    echo "error: GPU_DEVICES must select exactly TP_SIZE distinct devices from 0,1" >&2
    echo "       examples: TP_SIZE=1 GPU_DEVICES=1 or TP_SIZE=2 GPU_DEVICES=0,1" >&2
    exit 2
    ;;
esac
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1024 || PORT > 65535)); then
  echo "error: PORT must be an integer from 1024 through 65535 (got: $PORT)" >&2
  exit 2
fi
SPEC_ARGS=()
if [ "$SPEC_MTP" = "1" ]; then
  if [ "$TP_SIZE" -ge 2 ]; then
    echo "error: SPEC_MTP=1 is refused at TP_SIZE>=2: vLLM #52480 (qwen3_5 MTP drafter" >&2
    echo "       weight-load crash at TP>=2) is still open. Use TP_SIZE=1 until fixed." >&2
    exit 2
  fi
  case "$SPEC_TOKENS" in
    1|2|3) ;;
    *) echo "error: SPEC_TOKENS must be 1-3; depth 5 is unmeasured for this checkpoint" >&2; exit 2 ;;
  esac
  SPEC_ARGS=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":$SPEC_TOKENS}")
  echo "MTP speculative decoding enabled at depth $SPEC_TOKENS (TP1)."
  echo "Verify the image carries vLLM #51812 + #51674 before trusting long runs."
elif [ "$SPEC_MTP" != "0" ]; then
  echo "error: SPEC_MTP must be 0 or 1 (got: $SPEC_MTP)" >&2
  exit 2
fi

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: checkpoint not found at $MODEL_HOST — run scripts/inference/qwen38/download-qwen38-27b.sh first" >&2
  exit 1
fi

# Resolve the human operator even under `sudo`, then synchronize all model-specific
# key paths to one credential. This prevents a root-only key from
# silently replacing the credential Pi retrieves as the desktop user.
inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/qwen38"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$CONFIG_DIR/container.env"

# Keep the key out of Docker's command arguments and the host process list.
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

sudo mkdir -p "$CACHE_HOST"
sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$CACHE_HOST"

# Make relaunch idempotent, then reject a different server already owning the port.
docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$PORT" | grep -q .; then
  echo "error: TCP port $PORT is already in use; stop the current model server first" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label io.peterstorm.inference.physical-gpus="$GPU_DEVICES" \
  --gpus "\"device=$GPU_DEVICES\"" \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST":"$MODEL_CONTAINER":ro \
  -v "$CACHE_HOST":/root/.cache \
  -e CUDA_VISIBLE_DEVICES="$CONTAINER_CUDA_VISIBLE_DEVICES" \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMAGE@$DIGEST" \
  "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-27b \
  --dtype bfloat16 \
  --tensor-parallel-size "$TP_SIZE" \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --kv-cache-dtype auto \
  --mamba-ssm-cache-dtype float32 \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  "${SPEC_ARGS[@]}" \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"min_p":0.0,"presence_penalty":0.0,"repetition_penalty":1.0}' \
  --host 0.0.0.0 \
  --port "$PORT"

echo "Started '$NAME' with TP_SIZE=$TP_SIZE on physical GPU device(s) $GPU_DEVICES at :$PORT."
echo "First start downloads/compiles runtime kernels and may take several minutes."
echo "Follow:  docker logs -f $NAME"
echo "Health:  curl -fsS http://127.0.0.1:$PORT/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
