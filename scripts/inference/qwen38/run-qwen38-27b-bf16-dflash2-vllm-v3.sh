#!/usr/bin/env bash
# Launch Qwen3.8-27B BF16 + DFlash2 with BF16 KV on physical GPU0.
#
# Immutable TP1 successor to the official TP2 v2 profile. It keeps the same
# target/draft checkpoints, FP32 GDN state, and digest-pinned vLLM image while
# reserving physical GPU1 for the Nix-managed ComfyUI service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
inference_resolve_operator

IMAGE="vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
IMAGE_DIGEST="sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674"
IMAGE_AMD64_DIGEST="sha256:2786e1d3301cb1039a3695c20aafd15b608adefd4c8380c2ed1457b24813c4a4"
IMAGE_SOURCE_SHA="a9a17e7095a66ef6c6685a1c7ddd657781a78d3c"
IMAGE_REF="$IMAGE@$IMAGE_DIGEST"
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
DRAFT_HOST="${DFLASH2_DRAFT_HOST:-$INFERENCE_OPERATOR_HOME/Desktop/Qwen3.8-27B-DFlash2}"
DRAFT_CONTAINER="/models/incoai/Qwen3.8-27B-DFlash2"
DRAFT_PIN="incoai/Qwen3.8-27B-DFlash2@dedf8df68adfb1afeaf7b7480c0a0243108177b4"
CACHE_HOST="/models/vllm-cache/qwen38-bf16-dflash2-tp1-bf16kv-v3"
NAME="qwen38-27b-bf16-dflash2-vllm-v3"
DFLASH2_NUM_SPEC_TOKENS=7
GPU_DEVICE=0
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"
CONTAINER_ARCHIVE_DIR="${CONTAINER_ARCHIVE_DIR:-$INFERENCE_OPERATOR_HOME/.local/state/qwen38/container-archives}"
ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-14}"
ARCHIVE_MAX_COUNT="${ARCHIVE_MAX_COUNT:-20}"

for numeric in MAX_NUM_SEQS MAX_MODEL_LEN MAX_NUM_BATCHED_TOKENS MAX_GPU_POWER_LIMIT \
  MAX_EXISTING_GPU_MEMORY_MIB ARCHIVE_RETENTION_DAYS ARCHIVE_MAX_COUNT; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer (got: $value)" >&2
    exit 2
  fi
done
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0[.][0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" 'BEGIN { exit !(value > 0 && value < 1) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be a decimal between 0 and 1 (got: $GPU_MEMORY_UTILIZATION)" >&2
  exit 2
fi
if [ "$MAX_MODEL_LEN" -gt 262144 ]; then
  echo "error: MAX_MODEL_LEN exceeds the checkpoint-native 262144-token contract" >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: target checkpoint not found at $MODEL_HOST — run scripts/inference/qwen38/download-qwen38-27b.sh first" >&2
  exit 1
fi
if [ ! -e "$DRAFT_HOST/config.json" ]; then
  echo "error: DFlash2 checkpoint not found at $DRAFT_HOST — run scripts/inference/qwen38/download-qwen38-27b-dflash2-v2.sh first" >&2
  exit 1
fi
if [ ! -f "$DRAFT_HOST/.download-complete" ] \
  || ! grep -Fxq "$DRAFT_PIN" "$DRAFT_HOST/.download-complete"; then
  echo "error: DFlash2 checkpoint lacks the canonical v2 revision marker: $DRAFT_PIN" >&2
  echo "run scripts/inference/qwen38/download-qwen38-27b-dflash2-v2.sh to verify/reuse the weights" >&2
  exit 1
fi
if [ ! -f "$DRAFT_HOST/model.safetensors" ] \
  || [ "$(stat -c %s "$DRAFT_HOST/model.safetensors")" != 3848817896 ]; then
  echo "error: DFlash2 model.safetensors is missing or has the wrong size" >&2
  exit 1
fi
if ! jq -e '.architectures == ["DFlash2DraftModel"] and .dflash_config.block_size == 8' \
  "$DRAFT_HOST/config.json" >/dev/null 2>&1; then
  echo "error: $DRAFT_HOST is not the canonical native DFlash2 checkpoint" >&2
  exit 1
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
# Import probes prove the image carries native Qwen3.8/DFlash2 support. The
# source assertions additionally reject the 08-22/08-24 nightlies where PR
# #52560 hardcoded the v1 layer class and made every DFlash2 checkpoint unloadable.
if ! docker run --rm --entrypoint python3 "$IMAGE_REF" -c '
import inspect
from vllm.model_executor.models.qwen3_dflash import DFlashQwen3Model
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.worker.gpu.spec_decode.dflash2.speculator import DFlash2Speculator
supported = ModelRegistry.get_supported_archs()
source = inspect.getsource(DFlashQwen3Model)
assert "Qwen3_5ForConditionalGeneration" in supported
assert "DFlash2DraftModel" in supported
assert "decoder_layer_cls = DFlashQwen3DecoderLayer" in source
assert "self.decoder_layer_cls(" in source
assert DFlash2Speculator
' >/dev/null 2>&1; then
  echo "error: $IMAGE_REF lacks fixed native Qwen3.8 + DFlash2 support" >&2
  echo "expected Qwen3.8, DFlash2Speculator, and the #53435 decoder-layer indirection" >&2
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
if [ "$memory_used" -gt "$MAX_EXISTING_GPU_MEMORY_MIB" ]; then
  echo "error: GPU $GPU_DEVICE already uses ${memory_used} MiB (limit: ${MAX_EXISTING_GPU_MEMORY_MIB} MiB)" >&2
  exit 3
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/qwen38"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$CONFIG_DIR/vllm-dflash2-tp1-bf16kv-v3.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

if [ ! -d "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
  sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

if docker container inspect "$NAME" >/dev/null 2>&1; then
  archive_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  inference_install_private_dir "$CONTAINER_ARCHIVE_DIR"
  archive_base="$CONTAINER_ARCHIVE_DIR/$archive_stamp-$NAME"
  docker inspect --format='id={{.Id}} created={{.Created}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} image={{.Config.Image}}' \
    "$NAME" >"$archive_base.metadata"
  docker logs --timestamps "$NAME" 2>&1 | gzip -1 >"$archive_base.log.gz" || \
    echo "warning: container log archive was incomplete: $archive_base.log.gz" >&2
  inference_secure_operator_file "$archive_base.metadata"
  inference_secure_operator_file "$archive_base.log.gz"
fi
if [ -d "$CONTAINER_ARCHIVE_DIR" ]; then
  find "$CONTAINER_ARCHIVE_DIR" -maxdepth 1 -type f \
    \( -name '*.metadata' -o -name '*.log.gz' \) \
    -mtime "+$ARCHIVE_RETENTION_DAYS" -delete
  mapfile -t old_archives < <(find "$CONTAINER_ARCHIVE_DIR" -maxdepth 1 -type f -name "*-$NAME.log.gz" -printf '%p\n' | sort)
  if [ "${#old_archives[@]}" -gt "$ARCHIVE_MAX_COUNT" ]; then
    remove_count=$((${#old_archives[@]} - ARCHIVE_MAX_COUNT))
    for ((index = 0; index < remove_count; index++)); do
      archive_base="${old_archives[$index]%.log.gz}"
      rm -f "$archive_base.log.gz" "$archive_base.metadata"
    done
  fi
fi

docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8000' | grep -q .; then
  echo "error: TCP port 8000 is already in use; stop the current model server first" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label io.peterstorm.inference.physical-gpu="$GPU_DEVICE" \
  --label io.peterstorm.inference.release="official-vllm-dflash2-tp1-bf16kv-v3" \
  --gpus "device=$GPU_DEVICE" \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST":"$MODEL_CONTAINER":ro \
  -v "$DRAFT_HOST":"$DRAFT_CONTAINER":ro \
  -v "$CACHE_HOST":/root/.cache \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMAGE_REF" \
  "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-27b \
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
  --speculative-config "{\"method\":\"dflash\",\"model\":\"$DRAFT_CONTAINER\",\"num_speculative_tokens\":$DFLASH2_NUM_SPEC_TOKENS}" \
  --attention-backend flashinfer \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"min_p":0.0,"presence_penalty":0.0,"repetition_penalty":1.0}' \
  --host 0.0.0.0 \
  --port 8000

echo "Started '$NAME' on physical GPU $GPU_DEVICE with fixed official vLLM nightly $IMAGE_SOURCE_SHA."
echo "Profile: BF16 weights/KV, FP32 GDN state, TP1, DFlash2 speculative depth $DFLASH2_NUM_SPEC_TOKENS."
echo "Official multi-platform digest: $IMAGE_DIGEST"
echo "Official AMD64 manifest:       $IMAGE_AMD64_DIGEST"
echo "Follow:  docker logs -f $NAME"
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
echo "Switch:   bash $SCRIPT_DIR/switch-qwen38-backend-v5.sh dflash2-vllm-tp1-bf16kv"
echo "Metrics:  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^vllm:spec_decode_num_(drafts|accepted)' | head"
