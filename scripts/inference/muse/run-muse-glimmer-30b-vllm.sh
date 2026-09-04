#!/usr/bin/env bash
# shellcheck disable=SC1091 # Runtime-relative shared inference modules.
# Run one pinned Muse Glimmer 30B target with target-only or official DFlash decoding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-fp8-profile.sh
source "$SCRIPT_DIR/muse-glimmer-fp8-profile.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$SCRIPT_DIR/muse-glimmer-variant.sh"
inference_resolve_operator

TARGET_VARIANT="${MUSE_VLLM_TARGET:-fp8}"
SPECULATION="${MUSE_VLLM_SPECULATION:-target-only}"
GPU_DEVICE="${GPU_DEVICE:-0}"
PORT="${PORT:-8001}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-2}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-1200}"
IMAGE_REF="$MUSE_FP8_IMAGE@$MUSE_FP8_IMAGE_DIGEST"

case "$TARGET_VARIANT" in
  fp8)
    TARGET_REPO="$MUSE_FP8_TARGET_REPO"
    TARGET_REV="$MUSE_FP8_TARGET_REV"
    TARGET_HOST="$MUSE_FP8_TARGET_HOST"
    TARGET_CONTAINER="$MUSE_FP8_TARGET_CONTAINER"
    TARGET_MANIFEST="$MUSE_FP8_TARGET_MANIFEST"
    DRAFT_REPO="$MUSE_FP8_DRAFT_REPO"
    DRAFT_REV="$MUSE_FP8_DRAFT_REV"
    DRAFT_HOST="$MUSE_FP8_DRAFT_HOST"
    DRAFT_CONTAINER="$MUSE_FP8_DRAFT_CONTAINER"
    DRAFT_MANIFEST="$MUSE_FP8_DRAFT_MANIFEST"
    RUNTIME_CACHE="$MUSE_FP8_RUNTIME_CACHE"
    CONTAINER_NAME="$MUSE_FP8_CONTAINER_NAME"
    SERVED_MODEL="$MUSE_FP8_SERVED_MODEL"
    PROFILE_NAME="muse-glimmer-fp8"
    DEFAULT_GPU_MEMORY_UTILIZATION="0.62"
    DOWNLOAD_HINT="run scripts/inference/muse/download-muse-glimmer-30b-fp8.sh and wait for DOWNLOAD_COMPLETE"
    ;;
  blackfrost-bf16)
    export MUSE_MODELS_ROOT="$INFERENCE_OPERATOR_HOME/.local/state/creative-model-staging"
    muse_resolve_variant blackfrost
    TARGET_REPO="$MUSE_TARGET_REPO"
    TARGET_REV="$MUSE_TARGET_REV"
    TARGET_HOST="$MUSE_TARGET_HOST"
    TARGET_CONTAINER="$MUSE_TARGET_CONTAINER"
    TARGET_MANIFEST="$MUSE_TARGET_MANIFEST"
    DRAFT_REPO="$MUSE_DRAFT_REPO"
    DRAFT_REV="$MUSE_DRAFT_REV"
    DRAFT_HOST="$MUSE_DRAFT_HOST"
    DRAFT_CONTAINER="$MUSE_DRAFT_CONTAINER"
    DRAFT_MANIFEST="$MUSE_DRAFT_MANIFEST"
    RUNTIME_CACHE="$INFERENCE_OPERATOR_HOME/.cache/vllm/muse-glimmer-blackfrost-bf16-dflash"
    CONTAINER_NAME="muse-glimmer-30b-blackfrost-bf16-dflash-vllm"
    SERVED_MODEL="muse-glimmer-30b-blackfrost-bf16"
    PROFILE_NAME="muse-glimmer-blackfrost-bf16"
    DEFAULT_GPU_MEMORY_UTILIZATION="0.82"
    DOWNLOAD_HINT="complete and verify the pinned Blackfrost target and official Muse assistant staging checkpoints"
    ;;
  *)
    echo "error: MUSE_VLLM_TARGET must be fp8 or blackfrost-bf16" >&2
    exit 2
    ;;
esac
case "$SPECULATION" in
  target-only|dflash) ;;
  *) echo "error: MUSE_VLLM_SPECULATION must be target-only or dflash" >&2; exit 2 ;;
esac
case "$GPU_DEVICE" in
  0|1) ;;
  *) echo "error: GPU_DEVICE must be 0 or 1" >&2; exit 2 ;;
esac
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1024 || PORT > 65535)); then
  echo "error: PORT must be an integer from 1024 through 65535" >&2
  exit 2
fi
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-$DEFAULT_GPU_MEMORY_UTILIZATION}"
for numeric in MAX_MODEL_LEN MAX_NUM_SEQS MAX_NUM_BATCHED_TOKENS MAX_GPU_POWER_LIMIT MAX_EXISTING_GPU_MEMORY_MIB STARTUP_TIMEOUT_SECONDS; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer" >&2
    exit 2
  fi
done
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" 'BEGIN { exit !(value >= 0.40 && value <= 0.85) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be between 0.40 and 0.85" >&2
  exit 2
fi

image_id="$(docker image inspect "$IMAGE_REF" --format '{{.Id}}' 2>/dev/null)" || {
  echo "error: pinned Muse vLLM image is unavailable: $IMAGE_REF" >&2
  echo "run: docker pull $IMAGE_REF" >&2
  exit 1
}
if [ "$image_id" != "$MUSE_FP8_IMAGE_ID" ]; then
  echo "error: Muse vLLM image ID mismatch" >&2
  exit 1
fi
if ! docker run --rm --entrypoint python3 "$IMAGE_REF" -c '
from vllm.model_executor.models.registry import ModelRegistry
supported = ModelRegistry.get_supported_archs()
assert "MuseGlimmerForCausalLM" in supported
assert "MuseGlimmerForConditionalGeneration" in supported
assert "MuseGlimmerAssistantModel" in supported
assert "DFlashMuseGlimmerAssistantModel" in supported
' >/dev/null 2>&1; then
  echo "error: pinned vLLM image lacks native Muse Glimmer or Muse DFlash support" >&2
  exit 1
fi

inference_require_pinned_checkpoint \
  "$TARGET_HOST" "$TARGET_REPO@$TARGET_REV" "$TARGET_MANIFEST" "$DOWNLOAD_HINT"
if [ "$SPECULATION" = dflash ]; then
  inference_require_pinned_checkpoint \
    "$DRAFT_HOST" "$DRAFT_REPO@$DRAFT_REV" "$DRAFT_MANIFEST" "$DOWNLOAD_HINT"
fi

if systemctl is-active --quiet comfyui; then
  comfy_environment="$(systemctl show comfyui -p Environment --value)"
  if [[ " $comfy_environment " != *" CUDA_VISIBLE_DEVICES=1 "* ]]; then
    echo "error: active ComfyUI is not proven pinned to physical GPU1" >&2
    exit 3
  fi
fi

mapfile -t conflicting_containers < <(inference_profile_containers_except "$CONTAINER_NAME")
for container in "${conflicting_containers[@]}"; do
  inference_stop_container_if_present "$container"
done
inference_remove_container_if_present "$CONTAINER_NAME"

gpu_state="$(nvidia-smi --id="$GPU_DEVICE" --query-gpu=power.limit,memory.used --format=csv,noheader,nounits)" || {
  echo "error: physical GPU $GPU_DEVICE is not queryable" >&2
  exit 3
}
IFS=',' read -r power_cap memory_used <<<"$gpu_state"
power_cap="${power_cap//[[:space:]]/}"
memory_used="${memory_used//[[:space:]]/}"
if ! [[ "$power_cap" =~ ^[0-9]+([.][0-9]+)?$ && "$memory_used" =~ ^[0-9]+$ ]]; then
  echo "error: could not parse GPU state: $gpu_state" >&2
  exit 3
fi
if awk -v cap="$power_cap" -v maximum="$MAX_GPU_POWER_LIMIT" 'BEGIN { exit !(cap > maximum) }'; then
  echo "error: GPU $GPU_DEVICE power cap is ${power_cap}W; maximum is ${MAX_GPU_POWER_LIMIT}W" >&2
  exit 3
fi
if ((memory_used > MAX_EXISTING_GPU_MEMORY_MIB)); then
  echo "error: GPU $GPU_DEVICE already uses ${memory_used} MiB" >&2
  exit 3
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/muse-glimmer"
ENVFILE="$CONFIG_DIR/$TARGET_VARIANT-vllm.env"
inference_install_private_dir "$CONFIG_DIR"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF
mkdir -p "$RUNTIME_CACHE"
inference_require_cache_access "$RUNTIME_CACHE"

if ss -H -ltn "sport = :$PORT" | grep -q .; then
  echo "error: TCP port $PORT is already in use" >&2
  exit 1
fi

speculation_args=()
if [ "$SPECULATION" = dflash ]; then
  speculation_args=(
    --speculative-config
    "{\"method\":\"dflash\",\"model\":\"$DRAFT_CONTAINER\",\"num_speculative_tokens\":15}"
  )
fi

docker_args=(
  docker run -d --init
  --restart unless-stopped
  --name "$CONTAINER_NAME"
  --label io.peterstorm.inference.profile="$PROFILE_NAME"
  --label io.peterstorm.inference.physical-gpu="$GPU_DEVICE"
  --label io.peterstorm.inference.port="$PORT"
  --label io.peterstorm.inference.target-revision="$TARGET_REV"
  --label io.peterstorm.inference.draft-revision="$DRAFT_REV"
  --label io.peterstorm.inference.speculation="$SPECULATION"
  --gpus "\"device=$GPU_DEVICE\""
  --ipc=host
  --network host
  --ulimit memlock=-1
  --ulimit nofile=1048576
  --ulimit stack=67108864
  --env-file "$ENVFILE"
  -v "$TARGET_HOST:$TARGET_CONTAINER:ro"
  -v "$DRAFT_HOST:$DRAFT_CONTAINER:ro"
  -v "$RUNTIME_CACHE:/root/.cache"
  -e CUDA_VISIBLE_DEVICES=0
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID
  -e VLLM_NO_USAGE_STATS=1
  "$IMAGE_REF"
  "$TARGET_CONTAINER"
  --served-model-name "$SERVED_MODEL"
  --generation-config auto
  --tensor-parallel-size 1
  --max-model-len "$MAX_MODEL_LEN"
  --max-num-seqs "$MAX_NUM_SEQS"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --kv-cache-dtype auto
  --language-model-only
  --enable-prefix-caching
  --enable-chunked-prefill
  --enable-auto-tool-choice
  --tool-call-parser muse_glimmer
  --reasoning-parser muse_glimmer
  --default-chat-template-kwargs '{"reasoning_strength":"high"}'
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":64}'
  "${speculation_args[@]}"
  --host 0.0.0.0
  --port "$PORT"
)
"${docker_args[@]}" >/dev/null

endpoint_is_healthy() {
  printf 'silent\nshow-error\nfail\noutput = "/dev/null"\nurl = "http://127.0.0.1:%s/health"\nheader = "Authorization: Bearer %s"\n' \
    "$PORT" "$VLLM_API_KEY" | curl --config -
}

started_at="$(date +%s)"
while ! endpoint_is_healthy; do
  running_status=0
  inference_container_running "$CONTAINER_NAME" || running_status=$?
  if [ "$running_status" -ne 0 ]; then
    docker logs --tail 120 "$CONTAINER_NAME" >&2 2>/dev/null || true
    inference_quiesce_failed_container "$CONTAINER_NAME" || true
    exit 1
  fi
  if (($(date +%s) - started_at >= STARTUP_TIMEOUT_SECONDS)); then
    echo "error: Muse did not become healthy within ${STARTUP_TIMEOUT_SECONDS}s" >&2
    docker logs --tail 120 "$CONTAINER_NAME" >&2 2>/dev/null || true
    inference_quiesce_failed_container "$CONTAINER_NAME" || true
    exit 1
  fi
  sleep 5
done

echo "MUSE_VLLM_READY: $TARGET_VARIANT/$SPECULATION on physical GPU $GPU_DEVICE at http://127.0.0.1:$PORT/v1"
echo "Model: $SERVED_MODEL"
echo "API key: $INFERENCE_MUSE_KEYFILE"
