#!/usr/bin/env bash
# Multimodal TP2/EP2/DCP2 v84 profile with DFlash2-7 for GLM-5.3 EXL3 K4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
IMAGE_CONFIG="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
MODEL_HOST="${MODEL_HOST:-/models/GLM-5.3-Flash-EXL3-K4-v1}"
DFLASH_HOST="${DFLASH_HOST:-/models/GLM-5.3-Flash-DFlash2-v1}"
MODEL_CONTAINER="/model"
DFLASH_CONTAINER="/draft"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v3}"
NAME="glm53-flash-exl3-k4-vllm-sm120-v3"

GPU_ORDER="${GPU_ORDER:-1,0}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-98304}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2072}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.95}"
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
integer_in_range MAX_MODEL_LEN "$MAX_MODEL_LEN" 1 98304
integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 4
integer_in_range MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS" 1 2072
[ "$GPU_MEMORY_UTILIZATION" = 0.95 ] || {
  echo "error: multimodal v3 fixes GPU_MEMORY_UTILIZATION at 0.95 for encoder headroom" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned v84 image is absent; run scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v3-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local v84 image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
MODEL_HOST="$MODEL_HOST" "$SCRIPT_DIR/verify-glm53-flash-exl3-k4-v1.sh"
MODEL_HOST="$DFLASH_HOST" "$SCRIPT_DIR/verify-glm53-flash-dflash2-v1.sh"
[ "$(sha256sum "$SCRIPT_DIR/glm53-flash-multimodal-v1.jinja" | cut -d' ' -f1)" = \
  34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891 ] || {
  echo "error: checked-in official multimodal template identity differs" >&2
  exit 1
}
if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 EXL3 K4 v84 DFlash2 multimodal checkpoint and image preflight: PASS"
  exit 0
fi

if systemctl is-active --quiet comfyui.service 2>/dev/null; then
  echo "error: comfyui.service is active; stop it before reserving both GPUs" >&2
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
    echo "error: GPU $index has ${memory_used} MiB in use; stop every GPU workload" >&2
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
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/exl3-k4-vllm-sm120-v3.env"
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
  --label ai.peterstorm.inference.profile=glm53-flash-exl3-k4-vllm-sm120-v3 \
  --label ai.peterstorm.inference.checkpoint=brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51 \
  --label ai.peterstorm.inference.equivalent-target=brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b \
  --label ai.peterstorm.inference.draft=incoai/GLM-5.3-Flash-DFlash2@7d74cdd881ed7e32c31175984a67823127b66cfe \
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
  -v "$DFLASH_HOST:$DFLASH_CONTAINER:ro" \
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
  -e VLLM_NVFP4_MLA_DYNAMIC_SCALE=0 \
  -e VLLM_NVFP4_MLA_SCALES_FILE=/opt/glm53/calibration/glm53_nvfp4_mla_outer_scales_mtp_power2_v2.json \
  -e VLLM_EXL3_PREFILL_BLOCK_M=128 \
  -e VLLM_USE_B12X_DCP_A2A=1 \
  -e VLLM_ENABLE_PCIE_ALLREDUCE=1 \
  -e VLLM_PCIE_ALLREDUCE_BACKEND=cpp \
  -e VLLM_NO_USAGE_STATS=1 \
  -e HF_HUB_OFFLINE=1 \
  "$IMAGE" \
  serve "$MODEL_CONTAINER" \
  --served-model-name glm-5.3-flash-exl3-k4-vision \
  --host 0.0.0.0 \
  --port 8000 \
  --tensor-parallel-size 2 \
  --enable-expert-parallel \
  --decode-context-parallel-size 2 \
  --dcp-comm-backend a2a \
  --dtype bfloat16 \
  --load-format safetensors \
  --moe-backend b12x \
  --attention-backend B12X_MLA_SPARSE \
  --kv-cache-dtype nvfp4_ds_mla \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --enable-chunked-prefill \
  --no-enable-prefix-caching \
  --generation-config "$MODEL_CONTAINER" \
  --chat-template /opt/glm53/chat_template.multimodal.jinja \
  --mm-encoder-attn-backend TORCH_SDPA \
  --limit-mm-per-prompt '{"image":4,"video":0}' \
  --reasoning-parser glm45 \
  --enable-auto-tool-choice \
  --tool-call-parser glm47 \
  --disable-custom-all-reduce \
  --speculative-config '{"method":"dflash","model":"/draft","num_speculative_tokens":7,"draft_tensor_parallel_size":2,"draft_sample_method":"probabilistic","rejection_sample_method":"standard","attention_backend":"TRITON_ATTN","kv_cache_dtype":"auto"}'

printf "Started multimodal v84 profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v3 uses TP2/EP2/DCP2, 98,304 context, DFlash2-7, TORCH_SDPA vision, four images, and no video.'
