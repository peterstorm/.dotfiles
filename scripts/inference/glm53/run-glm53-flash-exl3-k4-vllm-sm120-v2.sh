#!/usr/bin/env bash
# Upstream-aligned text-only TP2/MTP3 v37 profile for GLM-5.3 EXL3 K4 on SM120.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="verdictai/glm53-flash-exl3-k4@sha256:bb0f2c524f3d55c03df25f62b4c7353fcce6a77468876028da2d6e58530c5f24"
IMAGE_CONFIG="sha256:8cdac4aa483d6be7bd1a18961e57dbeddefc102f9f786689eece8b8a7ed419aa"
MODEL_HOST="${MODEL_HOST:-/models/GLM-5.3-Flash-EXL3-K4-v1}"
MODEL_CONTAINER="/model"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v2}"
NAME="glm53-flash-exl3-k4-vllm-sm120-v2"

GPU_ORDER="${GPU_ORDER:-1,0}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-499968}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.988}"
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
integer_in_range MAX_MODEL_LEN "$MAX_MODEL_LEN" 1 499968
integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 4
integer_in_range MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS" 1 8192
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" 'BEGIN { exit !(value >= 0.95 && value <= 0.988) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be in [0.95, 0.988]" >&2
  exit 2
fi

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned v37 image is absent; run scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v2-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local v37 image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
MODEL_HOST="$MODEL_HOST" "$SCRIPT_DIR/verify-glm53-flash-exl3-k4-v1.sh"
if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 EXL3 K4 vLLM SM120 v2 checkpoint and image preflight: PASS"
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
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/exl3-k4-vllm-sm120-v2.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=glm53-flash-exl3-k4-vllm-sm120-v2 \
  --label ai.peterstorm.inference.checkpoint=brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51 \
  --label ai.peterstorm.inference.runtime-settings=brandonmusic/GLM-5.3-Flash-EXL3-4bpw@b526998ef7644d90569866ef1df82999e26dcbfc \
  --label ai.peterstorm.inference.image-config="$IMAGE_CONFIG" \
  --gpus all \
  --ipc=host \
  --shm-size 32g \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  --entrypoint /opt/venv/bin/vllm \
  -v "$MODEL_HOST:$MODEL_CONTAINER:ro" \
  -v "$CACHE_HOST:/cache" \
  -e CUDA_VISIBLE_DEVICES="$GPU_ORDER" \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e GLOO_SOCKET_IFNAME=lo \
  -e NCCL_SOCKET_IFNAME=lo \
  -e NCCL_IB_DISABLE=1 \
  -e NCCL_P2P_LEVEL=4 \
  -e NCCL_PROTO=LL,LL128,Simple \
  -e OMP_NUM_THREADS=2 \
  -e VLLM_ENGINE_READY_TIMEOUT_S=3600 \
  -e VLLM_B12X_GLM_NOPE_NVFP4=1 \
  -e VLLM_USE_B12X_DCP_A2A=1 \
  -e VLLM_B12X_MLA_CKV_GATHER=0 \
  -e VLLM_NO_USAGE_STATS=1 \
  -e HF_HUB_OFFLINE=1 \
  -e TORCH_CUDA_ARCH_LIST='12.0a' \
  -e FLASHINFER_CUDA_ARCH_LIST='12.0f' \
  "$IMAGE" \
  serve "$MODEL_CONTAINER" \
  --served-model-name glm-5.3-flash-exl3-k4 \
  --host 0.0.0.0 \
  --port 8000 \
  --language-model-only \
  --tensor-parallel-size 2 \
  --decode-context-parallel-size 1 \
  --dcp-comm-backend a2a \
  --dtype bfloat16 \
  --load-format safetensors \
  --quantization exl3 \
  --moe-backend b12x \
  --attention-backend B12X_MLA_SPARSE \
  --kv-cache-dtype nvfp4_ds_mla \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --enable-chunked-prefill \
  --enable-prefix-caching \
  --generation-config "$MODEL_CONTAINER" \
  --reasoning-parser glm45 \
  --enable-auto-tool-choice \
  --tool-call-parser glm47 \
  --disable-custom-all-reduce \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'

printf "Started upstream-aligned profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v2 uses the upstream v37 TP2 daily-driver envelope: 499,968 context, C4, prefix caching, graphs, and MTP3.'
