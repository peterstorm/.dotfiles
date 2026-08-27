#!/usr/bin/env bash
# Experimental TP2 Qwen3.8-Flash-Next FP8 profile with its 51.2B N-gram table in host RAM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3"
IMAGE_CONFIG="sha256:bd995759b5b8ac51062e04c9e4d7c91c382d1ba377bb787e24dca2ccb39925e9"
MODEL_HOST="${MODEL_HOST:-/models/Qwen3.8-Flash-Next-FP8-v1}"
MODEL_CONTAINER="/model"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/qwen38-flash-next-fp8-v1}"
TMP_HOST="${TMP_HOST:-$CACHE_HOST/tmp}"
NAME="qwen38-flash-next-fp8-vllm-v1"

GPU_ORDER="${GPU_ORDER:-0,1}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.94}"
OMP_NUM_THREADS="${OMP_NUM_THREADS:-16}"
EXPECTED_POWER_LIMIT_WATTS="450"
MIN_AVAILABLE_RAM_KIB=62914560
MODE="${1:---launch}"

integer_in_range() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < minimum || value > maximum )); then
    echo "error: $name must be an integer in [$minimum, $maximum]" >&2
    exit 2
  fi
}

case "$MODE" in
  --launch|--preflight) ;;
  *) echo "usage: ${0##*/} [--launch|--preflight]" >&2; exit 2 ;;
esac
case "$GPU_ORDER" in
  0,1|1,0) ;;
  *) echo "error: GPU_ORDER must contain both physical GPUs exactly once: 0,1 or 1,0" >&2; exit 2 ;;
esac
integer_in_range MAX_MODEL_LEN "$MAX_MODEL_LEN" 1 262144
integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 4
integer_in_range OMP_NUM_THREADS "$OMP_NUM_THREADS" 1 32
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" 'BEGIN { exit !(value >= 0.90 && value <= 0.96) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be in [0.90, 0.96]" >&2
  exit 2
fi

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned Flash-Next image is absent; run scripts/inference/qwen38/pull-qwen38-flash-next-vllm-v1-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local Flash-Next image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
MODEL_HOST="$MODEL_HOST" "$SCRIPT_DIR/verify-qwen38-flash-next-fp8-v1.sh"
if [ "$MODE" = --preflight ]; then
  echo "Qwen3.8-Flash-Next FP8 vLLM v1 checkpoint and image preflight: PASS"
  exit 0
fi

if systemctl is-active --quiet comfyui.service 2>/dev/null; then
  echo "error: comfyui.service is active; stop it before reserving host RAM and both GPUs" >&2
  exit 1
fi

mem_total_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
mem_available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
if [ -z "$mem_total_kib" ] || [ -z "$mem_available_kib" ] \
  || (( mem_total_kib < 94371840 )); then
  echo "error: Flash-Next RAM offload requires a host with at least 90 GiB of RAM" >&2
  exit 1
fi
if (( mem_available_kib < MIN_AVAILABLE_RAM_KIB )); then
  echo "error: only $((mem_available_kib / 1024)) MiB RAM is available; at least $((MIN_AVAILABLE_RAM_KIB / 1024)) MiB is required for the FP8 N-gram table and runtime" >&2
  exit 1
fi

mapfile -t gpu_rows < <(nvidia-smi \
  --query-gpu=index,name,memory.total,memory.used,power.limit \
  --format=csv,noheader,nounits)
[ "${#gpu_rows[@]}" -eq 2 ] || {
  echo "error: this profile requires exactly two GPUs; found ${#gpu_rows[@]}" >&2
  exit 1
}
for row in "${gpu_rows[@]}"; do
  IFS=, read -r index name memory_total memory_used power_limit <<<"$row"
  index="${index//[[:space:]]/}"
  name="${name# }"
  memory_total="${memory_total//[[:space:]]/}"
  memory_used="${memory_used//[[:space:]]/}"
  power_limit="${power_limit//[[:space:]]/}"
  [[ "$name" == *"RTX PRO 6000 Blackwell"* ]] || {
    echo "error: GPU $index is not an RTX PRO 6000 Blackwell: $name" >&2
    exit 1
  }
  (( memory_total >= 97000 )) || {
    echo "error: GPU $index exposes only ${memory_total} MiB; the profile requires 96 GB-class cards" >&2
    exit 1
  }
  (( memory_used <= 1024 )) || {
    echo "error: GPU $index has ${memory_used} MiB in use; stop ComfyUI and every GPU workload" >&2
    exit 1
  }
  awk -v actual="$power_limit" -v expected="$EXPECTED_POWER_LIMIT_WATTS" \
    'BEGIN { exit !(actual >= expected - 0.1 && actual <= expected + 0.1) }' || {
      echo "error: GPU $index power limit is ${power_limit} W, expected ${EXPECTED_POWER_LIMIT_WATTS} W" >&2
      exit 1
    }
done

inference_remove_container_if_present "$NAME"
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  echo "error: host port 8000 is already listening; stop the active Qwen/DeepSeek/GLM profile first" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/qwen38/flash-next-fp8-vllm-v1.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

for directory in "$CACHE_HOST" "$TMP_HOST"; do
  if ! mkdir -p "$directory" 2>/dev/null || [ ! -w "$directory" ]; then
    sudo mkdir -p "$directory"
  fi
  inference_require_cache_access "$directory"
done

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=qwen38-flash-next-fp8-vllm-v1 \
  --label ai.peterstorm.inference.checkpoint=Qwen/Qwen3.8-Flash-Next-FP8@970c569adaca6b35532111fd6b27351b2baefe50 \
  --label ai.peterstorm.inference.image-config="$IMAGE_CONFIG" \
  --gpus all \
  --ipc=host \
  --shm-size 32g \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST:$MODEL_CONTAINER:ro" \
  -v "$CACHE_HOST:/cache" \
  -v "$CACHE_HOST:/root/.cache" \
  -v "$TMP_HOST:/container-tmp" \
  -e CUDA_VISIBLE_DEVICES="$GPU_ORDER" \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e HF_HUB_OFFLINE=1 \
  -e VLLM_PLE_CPU_OFFLOAD=1 \
  -e TMPDIR=/container-tmp \
  -e TRITON_CACHE_DIR=/cache/triton \
  -e PYTHONHASHSEED=0 \
  -e OMP_NUM_THREADS="$OMP_NUM_THREADS" \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMAGE" \
  "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-flash-next-fp8 \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2 \
  --max-model-len "$MAX_MODEL_LEN" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --enable-prefix-caching \
  --no-enable-flashinfer-autotune \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3 \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
  --limit-mm-per-prompt '{"image":1,"video":0}'

printf "Started experimental profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'The 51.2B-element FP8 N-gram table is mandatory-offloaded to host RAM; do not disable VLLM_PLE_CPU_OFFLOAD.'
