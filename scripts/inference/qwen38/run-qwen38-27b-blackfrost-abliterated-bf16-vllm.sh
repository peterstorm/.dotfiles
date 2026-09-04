#!/usr/bin/env bash
# Launch Blackfrost's abliterated Qwen3.8-27B BF16 master through the qualified
# TP1 vLLM profile.
#
# The checkpoint is a weight-level derivative of Qwen/Qwen3.8-27B with a reduced
# refusal surface and is structurally identical to /models/Qwen3.8-27B, so it
# reuses the v3 profile's digest-pinned image, parsers, and GPU policy unchanged.
# Only the target weights and the served name differ.
#
# Decoding defaults to target-only. DFlash2 speculation pairs the official draft
# with an abliterated target, which is the same cross-pairing Muse Blackfrost
# uses, but it stays opt-in until target-only output has been compared here —
# the qualification rule the Muse FP8 runbook already sets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
inference_resolve_operator

IMAGE="vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
IMAGE_DIGEST="sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674"
IMAGE_SOURCE_SHA="a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
IMAGE_REF="$IMAGE@$IMAGE_DIGEST"
MODEL_HOST="${MODEL_HOST:-/models/Qwen3.8-27B-Blackfrost-Abliterated-BF16}"
MODEL_CONTAINER="/models/Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16"
MODEL_PIN="Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16@9d85770e5eb602322b4bceef55beda357e0bd0ca"
DRAFT_HOST="${DFLASH2_DRAFT_HOST:-$INFERENCE_OPERATOR_HOME/Desktop/Qwen3.8-27B-DFlash2}"
DRAFT_CONTAINER="/models/incoai/Qwen3.8-27B-DFlash2"
DRAFT_PIN="incoai/Qwen3.8-27B-DFlash2@dedf8df68adfb1afeaf7b7480c0a0243108177b4"
CACHE_HOST="/models/vllm-cache/qwen38-27b-blackfrost-abliterated-bf16"
NAME="qwen38-27b-blackfrost-abliterated-bf16-vllm"
SERVED_MODEL="qwen3.8-27b-blackfrost-abliterated"
SPECULATION="${QWEN_BLACKFROST_SPECULATION:-target-only}"
DFLASH2_NUM_SPEC_TOKENS=7
GPU_DEVICE="${GPU_DEVICE:-0}"
PORT="${PORT:-8000}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-1200}"

case "$SPECULATION" in
  target-only|dflash2) ;;
  *) echo "error: QWEN_BLACKFROST_SPECULATION must be target-only or dflash2" >&2; exit 2 ;;
esac
case "$GPU_DEVICE" in
  0|1) ;;
  *) echo "error: GPU_DEVICE must be 0 or 1 (got: $GPU_DEVICE)" >&2; exit 2 ;;
esac
for numeric in PORT MAX_NUM_SEQS MAX_MODEL_LEN MAX_NUM_BATCHED_TOKENS MAX_GPU_POWER_LIMIT \
  MAX_EXISTING_GPU_MEMORY_MIB STARTUP_TIMEOUT_SECONDS; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer (got: $value)" >&2
    exit 2
  fi
done
if ((PORT < 1024 || PORT > 65535)); then
  echo "error: PORT must be an integer from 1024 through 65535" >&2
  exit 2
fi
if ((MAX_MODEL_LEN > 262144)); then
  echo "error: MAX_MODEL_LEN exceeds the checkpoint-native 262144-token contract" >&2
  exit 2
fi
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0[.][0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" 'BEGIN { exit !(value > 0 && value < 1) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be a decimal between 0 and 1 (got: $GPU_MEMORY_UTILIZATION)" >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# The downloader already proved every artifact against the pinned manifest, so
# the launcher checks identity rather than rehashing 51.77 GiB on every start.
if [ ! -f "$MODEL_HOST/.download-complete" ] \
  || ! grep -Fxq "$MODEL_PIN" "$MODEL_HOST/.download-complete"; then
  echo "error: target checkpoint at $MODEL_HOST lacks the pinned revision marker: $MODEL_PIN" >&2
  echo "run scripts/inference/qwen38/download-qwen38-27b-blackfrost-abliterated-bf16.sh" >&2
  exit 1
fi
if ! jq -e '
  .architectures == ["Qwen3_5ForConditionalGeneration"] and
  .model_type == "qwen3_5" and
  .text_config.model_type == "qwen3_5_text" and
  .text_config.max_position_embeddings == 262144 and
  .text_config.num_hidden_layers == 64 and
  (has("quantization_config") | not)
' "$MODEL_HOST/config.json" >/dev/null 2>&1; then
  echo "error: $MODEL_HOST is not the unquantized Qwen3.8-27B architecture this profile serves" >&2
  exit 1
fi

if [ "$SPECULATION" = dflash2 ]; then
  if [ ! -f "$DRAFT_HOST/.download-complete" ] \
    || ! grep -Fxq "$DRAFT_PIN" "$DRAFT_HOST/.download-complete"; then
    echo "error: DFlash2 checkpoint lacks the canonical revision marker: $DRAFT_PIN" >&2
    echo "run scripts/inference/qwen38/download-qwen38-27b-dflash2-v2.sh first" >&2
    exit 1
  fi
  if ! jq -e '.architectures == ["DFlash2DraftModel"] and .dflash_config.block_size == 8' \
    "$DRAFT_HOST/config.json" >/dev/null 2>&1; then
    echo "error: $DRAFT_HOST is not the canonical native DFlash2 checkpoint" >&2
    exit 1
  fi
fi

if ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  echo "error: fixed official vLLM image is not present: $IMAGE_REF" >&2
  echo "pull it with: bash $SCRIPT_DIR/pull-qwen38-dflash2-vllm-v2-image.sh" >&2
  exit 1
fi
actual_source_sha="$(docker image inspect --format '{{index .Config.Labels "ai.vllm.build.commit"}}' "$IMAGE_REF")"
if [ "$actual_source_sha" != "$IMAGE_SOURCE_SHA" ]; then
  echo "error: $IMAGE_REF source label is $actual_source_sha, expected $IMAGE_SOURCE_SHA" >&2
  exit 1
fi
if ! docker run --rm --entrypoint python3 "$IMAGE_REF" -c '
from vllm.model_executor.models.registry import ModelRegistry
assert "Qwen3_5ForConditionalGeneration" in ModelRegistry.get_supported_archs()
' >/dev/null 2>&1; then
  echo "error: $IMAGE_REF lacks native Qwen3.8 support" >&2
  exit 1
fi
if [ "$SPECULATION" = dflash2 ] && ! docker run --rm --entrypoint python3 "$IMAGE_REF" -c '
import inspect
from vllm.model_executor.models.qwen3_dflash import DFlashQwen3Model
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.worker.gpu.spec_decode.dflash2.speculator import DFlash2Speculator
source = inspect.getsource(DFlashQwen3Model)
assert "DFlash2DraftModel" in ModelRegistry.get_supported_archs()
assert "decoder_layer_cls = DFlashQwen3DecoderLayer" in source
assert "self.decoder_layer_cls(" in source
assert DFlash2Speculator
' >/dev/null 2>&1; then
  echo "error: $IMAGE_REF lacks fixed native DFlash2 support" >&2
  exit 1
fi

if systemctl is-active --quiet comfyui.service 2>/dev/null; then
  comfy_environment="$(systemctl show comfyui.service -p Environment --value)"
  if [[ " $comfy_environment " != *" CUDA_VISIBLE_DEVICES=1 "* ]]; then
    echo "error: active ComfyUI is not proven pinned to physical GPU1" >&2
    exit 3
  fi
fi

gpu_state="$(nvidia-smi --id="$GPU_DEVICE" --query-gpu=index,power.limit,memory.used --format=csv,noheader,nounits 2>/dev/null)" || {
  echo "error: physical GPU $GPU_DEVICE is not queryable" >&2
  exit 3
}
IFS=',' read -r gpu_index power_cap memory_used <<<"$gpu_state"
gpu_index="${gpu_index//[[:space:]]/}"
power_cap="${power_cap//[[:space:]]/}"
memory_used="${memory_used//[[:space:]]/}"
if [ "$gpu_index" != "$GPU_DEVICE" ] \
  || ! [[ "$power_cap" =~ ^[0-9]+([.][0-9]+)?$ && "$memory_used" =~ ^[0-9]+$ ]]; then
  echo "error: could not parse GPU $GPU_DEVICE state: $gpu_state" >&2
  exit 3
fi
if awk -v cap="$power_cap" -v maximum="$MAX_GPU_POWER_LIMIT" 'BEGIN { exit !(cap > maximum) }'; then
  echo "error: GPU $GPU_DEVICE cap is ${power_cap}W; profile maximum is ${MAX_GPU_POWER_LIMIT}W" >&2
  exit 3
fi
# Refuses rather than colliding: Muse holding this card is a GPU_DEVICE mistake,
# not something to overwrite. Run beside Muse with GPU_DEVICE=1 and ComfyUI down.
if [ "$memory_used" -gt "$MAX_EXISTING_GPU_MEMORY_MIB" ]; then
  echo "error: GPU $GPU_DEVICE already uses ${memory_used} MiB (limit: ${MAX_EXISTING_GPU_MEMORY_MIB} MiB)" >&2
  exit 3
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/qwen38"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$CONFIG_DIR/vllm-blackfrost-abliterated-bf16.env"
inference_install_private_dir "$CONFIG_DIR"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

if [ ! -d "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
  sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$PORT" | grep -q .; then
  echo "error: TCP port $PORT is already in use; stop the current model server first" >&2
  exit 1
fi

speculation_args=()
draft_mount=()
if [ "$SPECULATION" = dflash2 ]; then
  speculation_args=(
    --speculative-config
    "{\"method\":\"dflash\",\"model\":\"$DRAFT_CONTAINER\",\"num_speculative_tokens\":$DFLASH2_NUM_SPEC_TOKENS}"
  )
  draft_mount=(-v "$DRAFT_HOST:$DRAFT_CONTAINER:ro")
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label io.peterstorm.inference.profile="qwen38-27b-blackfrost-abliterated-bf16" \
  --label io.peterstorm.inference.physical-gpu="$GPU_DEVICE" \
  --label io.peterstorm.inference.port="$PORT" \
  --label io.peterstorm.inference.target-revision="$MODEL_PIN" \
  --label io.peterstorm.inference.speculation="$SPECULATION" \
  --gpus "device=$GPU_DEVICE" \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST":"$MODEL_CONTAINER":ro \
  "${draft_mount[@]}" \
  -v "$CACHE_HOST":/root/.cache \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMAGE_REF" \
  "$MODEL_CONTAINER" \
  --served-model-name "$SERVED_MODEL" \
  --dtype bfloat16 \
  --tensor-parallel-size 1 \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --kv-cache-dtype auto \
  --mamba-ssm-cache-dtype float32 \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  "${speculation_args[@]}" \
  --attention-backend flashinfer \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"min_p":0.0,"presence_penalty":0.0,"repetition_penalty":1.0}' \
  --host 0.0.0.0 \
  --port "$PORT" >/dev/null

endpoint_is_healthy() {
  printf 'silent\nshow-error\nfail\noutput = "/dev/null"\nurl = "http://127.0.0.1:%s/health"\nheader = "Authorization: Bearer %s"\n' \
    "$PORT" "$VLLM_API_KEY" | curl --config -
}

started_at="$(date +%s)"
while ! endpoint_is_healthy; do
  running_status=0
  inference_container_running "$NAME" || running_status=$?
  if [ "$running_status" -ne 0 ]; then
    docker logs --tail 120 "$NAME" >&2 2>/dev/null || true
    inference_quiesce_failed_container "$NAME" || true
    exit 1
  fi
  if (($(date +%s) - started_at >= STARTUP_TIMEOUT_SECONDS)); then
    echo "error: Blackfrost Qwen did not become healthy within ${STARTUP_TIMEOUT_SECONDS}s" >&2
    docker logs --tail 120 "$NAME" >&2 2>/dev/null || true
    inference_quiesce_failed_container "$NAME" || true
    exit 1
  fi
  sleep 5
done

echo "QWEN_BLACKFROST_READY: $SPECULATION on physical GPU $GPU_DEVICE at http://127.0.0.1:$PORT/v1"
echo "Model: $SERVED_MODEL"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
echo "Follow:  docker logs -f $NAME"
