#!/usr/bin/env bash
# Experimental multimodal TP2 vLLM profile for GLM-5.3 NVFP4 on RTX PRO 6000 SM120.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="cstechdev/vllm:glm53-flash-nope-sm120-cu130-20260826-r1@sha256:0bd709e80b8ff13ae5de8f7d7f708a499fade3a26970d56afb1be2ff3860fde5"
IMAGE_CONFIG="sha256:136b60b807401679fb529b5fc99ce86c8ec291b38ef01c75801c76696e995be3"
MODEL_HOST="${MODEL_HOST:-/models/GLM-5.3-Flash-NVFP4-v1}"
MODEL_CONTAINER="/models/local-inference-lab/GLM-5.3-Flash-NVFP4-v1"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-nvfp4-sm120-v2}"
NAME="glm53-flash-nvfp4-vllm-sm120-v2"

GPU_ORDER="${GPU_ORDER:-1,0}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
# Upstream's 1024 default exceeds the available hybrid KDA/Mamba cache blocks.
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.95}"
CPU_OFFLOAD_GB="${CPU_OFFLOAD_GB:-0}"
EXPECTED_POWER_LIMIT_WATTS="450"
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
integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 8
integer_in_range MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS" 1 8192
integer_in_range CPU_OFFLOAD_GB "$CPU_OFFLOAD_GB" 0 32
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" 'BEGIN { exit !(value >= 0.90 && value <= 0.98) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be in [0.90, 0.98]" >&2
  exit 2
fi

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned SM120 image is absent; run scripts/inference/glm53/pull-glm53-flash-vllm-sm120-v2-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local SM120 image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
"$SCRIPT_DIR/verify-glm53-flash-nvfp4-v1.sh"
if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 multimodal vLLM SM120 v2 checkpoint and image preflight: PASS"
  exit 0
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
    echo "error: GPU $index has ${memory_used} MiB in use; stop all GPU workloads and the display manager" >&2
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
  echo "error: host port 8000 is already listening; stop the active Qwen/DeepSeek profile first" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/vllm-sm120-v2.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

sudo mkdir -p "$CACHE_HOST"
inference_require_cache_access "$CACHE_HOST"

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=glm53-flash-nvfp4-vllm-sm120-v2 \
  --label ai.peterstorm.inference.checkpoint=local-inference-lab/GLM-5.3-Flash-NVFP4@520de24eabf507659eaef7c70f14fd584527facc \
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
  -v "$CACHE_HOST:/root/.cache" \
  -e CUDA_VISIBLE_DEVICES="$GPU_ORDER" \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e GLOO_SOCKET_IFNAME=lo \
  -e NCCL_SOCKET_IFNAME=lo \
  -e VLLM_NO_USAGE_STATS=1 \
  -e HF_HUB_OFFLINE=1 \
  -e VLLM_ATTENTION_BACKEND=FLASHINFER_MLA_SPARSE_SM120 \
  -e TORCH_CUDA_ARCH_LIST='12.0a' \
  -e FLASHINFER_CUDA_ARCH_LIST='12.0f' \
  "$IMAGE" \
  "$MODEL_CONTAINER" \
  --served-model-name glm-5.3-flash-nvfp4 \
  --tensor-parallel-size 2 \
  --dtype bfloat16 \
  --quantization modelopt_mixed \
  --moe-backend marlin \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --cpu-offload-gb "$CPU_OFFLOAD_GB" \
  --kv-cache-dtype fp8_ds_mla \
  --mamba-cache-mode none \
  --mamba-ssm-cache-dtype bfloat16 \
  --enforce-eager \
  --disable-custom-all-reduce \
  --no-enable-prefix-caching \
  --no-enable-flashinfer-autotune \
  --limit-mm-per-prompt '{"image":1,"video":0}' \
  --mm-processor-cache-type shm \
  --enable-auto-tool-choice \
  --reasoning-parser glm45 \
  --tool-call-parser glm47 \
  --generation-config vllm \
  --host 0.0.0.0 \
  --port 8000

printf "Started experimental profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'Do not promote it until every TP2, image, 262K, tool, and soak gate passes.'
