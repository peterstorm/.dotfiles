#!/usr/bin/env bash
# Graph-enabled TP2/EP2/DCP1 MTP3 + prefix-cache candidate with fast exact top-k.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2"
IMAGE_CONFIG="sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2"
MODEL_HOST="${MODEL_HOST:-$HOME/models/GLM-5.3-Flash-EXL3-K4-v1}"
MODEL_CONTAINER="/model"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v9}"
NAME="glm53-flash-exl3-k4-vllm-sm120-v9"
SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v9"

GPU_ORDER="${GPU_ORDER:-1,0}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-359000}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.986}"
EXPECTED_POWER_LIMIT_WATTS="450"
MODE="${1:---launch}"

integer_in_range() {
  local name="$1" value="$2" minimum="$3" maximum="$4"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value < minimum || value > maximum)); then
    echo "error: $name must be an integer in [$minimum, $maximum]" >&2
    exit 2
  fi
}

case "$MODE" in
  --launch | --preflight) ;;
  *) echo "usage: ${0##*/} [--launch|--preflight]" >&2; exit 2 ;;
esac
case "$GPU_ORDER" in
  0,1 | 1,0) ;;
  *) echo "error: GPU_ORDER must contain both physical GPUs exactly once: 0,1 or 1,0" >&2; exit 2 ;;
esac
integer_in_range MAX_MODEL_LEN "$MAX_MODEL_LEN" 1 359000
integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 4
integer_in_range MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS" 1 2048
[ "$GPU_MEMORY_UTILIZATION" = 0.986 ] || {
  echo "error: graph-enabled multimodal FP8-DS-MLA v9 fixes GPU_MEMORY_UTILIZATION at 0.986" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned GLM v9 image is absent; run scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v9-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local GLM v9 image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
MODEL_HOST="$MODEL_HOST" "$SCRIPT_DIR/verify-glm53-flash-exl3-k4-v1.sh"
if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 v9 graph-enabled MTP3 + prefix-state-safe multimodal FP8-DS-MLA 359K preflight: PASS"
  echo "Capacity is intentionally not predicted: the switcher must print and persist the exact local boot allocation."
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
  ((memory_total >= 97000)) || {
    echo "error: GPU $index exposes only ${memory_total} MiB; the profile requires 96 GB-class cards" >&2
    exit 1
  }
  ((memory_used <= 1024)) || {
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
  echo "error: host port 8000 is already listening; use the v9 switcher when ready to replace the active profile" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/exl3-k4-vllm-sm120-v9.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

docker run -d --init \
  --restart no \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=glm53-flash-exl3-k4-vllm-sm120-v9 \
  --label ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v9-boot \
  --label ai.peterstorm.inference.checkpoint=brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51 \
  --label ai.peterstorm.inference.equivalent-target=brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b \
  --label ai.peterstorm.inference.speculation=mtp3 \
  --label ai.peterstorm.inference.prefix-cache=mandatory \
  --label ai.peterstorm.inference.state-safety=pr50021-pr50729-pr54296-plus-cpu-mixed-partition \
  --label ai.peterstorm.inference.exact-sparse-topk=pr52149-overflow-radix-deterministic-ties \
  --label ai.peterstorm.inference.kpool-tail=persistent-circular-slot-buffer \
  --label ai.peterstorm.inference.graph-mode=cudagraph-dcp1-candidate \
  --label ai.peterstorm.inference.kv-cache=fp8_ds_mla \
  --label ai.peterstorm.inference.image-config="$IMAGE_CONFIG" \
  --gpus all \
  --ipc=host \
  --shm-size 32g \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576:1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST:$MODEL_CONTAINER:ro" \
  -v "$CACHE_HOST:/cache:rw" \
  -e CUDA_VISIBLE_DEVICES="$GPU_ORDER" \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e GLOO_SOCKET_IFNAME=lo \
  -e NCCL_SOCKET_IFNAME=lo \
  -e NCCL_P2P_LEVEL=4 \
  -e NCCL_IB_DISABLE=1 \
  -e NCCL_ALGO=Ring \
  -e NCCL_PROTO=Simple \
  -e CUDA_DEVICE_MAX_CONNECTIONS=1 \
  -e CUBLAS_WORKSPACE_CONFIG=:4096:8 \
  -e OMP_NUM_THREADS=2 \
  -e VLLM_ENGINE_READY_TIMEOUT_S=3600 \
  -e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0 \
  -e VLLM_B12X_GLM_NOPE_NVFP4=0 \
  -e VLLM_EXL3_PREFILL_BLOCK_M=128 \
  -e VLLM_EXL3_PREFILL_TRELLIS=1 \
  -e B12X_GL53_ROUTE128_WIDE=1 \
  -e B12X_GL53_ROUTE128_HYBRID_TAIL=1 \
  -e VLLM_ENABLE_PCIE_ALLREDUCE=1 \
  -e VLLM_PCIE_ALLREDUCE_BACKEND=cpp \
  -e VLLM_NO_USAGE_STATS=1 \
  -e HF_HUB_OFFLINE=1 \
  -e TRANSFORMERS_OFFLINE=1 \
  "$IMAGE" \
  serve "$MODEL_CONTAINER" \
  --served-model-name "$SERVED_MODEL" \
  --host 0.0.0.0 \
  --port 8000 \
  --enable-prompt-tokens-details \
  --tensor-parallel-size 2 \
  --decode-context-parallel-size 1 \
  --dtype bfloat16 \
  --kv-cache-dtype fp8_ds_mla \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --moe-backend b12x \
  --attention-backend FLASHINFER_MLA_SPARSE_SM120 \
  --load-format safetensors \
  --enable-expert-parallel \
  --enable-chunked-prefill \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --reasoning-parser glm45 \
  --tool-call-parser glm47 \
  --generation-config "$MODEL_CONTAINER" \
  --chat-template /opt/glm53/chat_template.multimodal.jinja \
  --mm-encoder-attn-backend TORCH_SDPA \
  --limit-mm-per-prompt '{"image":4,"video":0}' \
  --disable-custom-all-reduce \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"greedy"}'

printf "Started multimodal FP8-DS-MLA MTP3 359K profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v9 uses TP2/EP2/DCP1 with CUDA graphs, 359,000 context, FP8 DS MLA KV, vision, mandatory prefix caching + MTP3, bounded/overlap-safe recurrent state, bounded slot maps, persistent KPool slots, and fast exact sparse top-k.'
printf '%s\n' 'The v9 switcher records exact KV capacity but deliberately retains restart=no until output-equivalence, mixed-traffic, and soak gates pass.'
