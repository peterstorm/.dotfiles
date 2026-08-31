#!/usr/bin/env bash
# Graph-enabled TP2/EP2/DCP2 B12X MTP3 + prefix-cache candidate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="sha256:ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553"
IMAGE_CONFIG="sha256:ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553"
MODEL_HOST="${MODEL_HOST:-$HOME/models/GLM-5.3-Flash-EXL3-K4-v1}"
MODEL_CONTAINER="/model"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v10}"
NAME="glm53-flash-exl3-k4-vllm-sm120-v10"
SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10"

GPU_ORDER="${GPU_ORDER:-1,0}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-359000}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"
KV_CACHE_MEMORY_BYTES="${KV_CACHE_MEMORY_BYTES:-3758096384}"
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
[ "$KV_CACHE_MEMORY_BYTES" = 3758096384 ] || {
  echo "error: v10 fixes KV_CACHE_MEMORY_BYTES at 3758096384 (3.5 GiB/GPU) to preserve DCP2 runtime headroom" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned GLM v10 image is absent; run scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v10-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local GLM v10 image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
MODEL_HOST="$MODEL_HOST" "$SCRIPT_DIR/verify-glm53-flash-exl3-k4-v1.sh"
if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 v10 graph-enabled MTP3 + prefix-state-safe multimodal FP8-DS-MLA 359K preflight: PASS"
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
  echo "error: host port 8000 is already listening; use the v10 switcher when ready to replace the active profile" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/exl3-k4-vllm-sm120-v10.env"
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
  --label ai.peterstorm.inference.profile=glm53-flash-exl3-k4-vllm-sm120-v10 \
  --label ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v10-boot \
  --label ai.peterstorm.inference.checkpoint=brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51 \
  --label ai.peterstorm.inference.equivalent-target=brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b \
  --label ai.peterstorm.inference.speculation=mtp3 \
  --label ai.peterstorm.inference.prefix-cache=mandatory \
  --label ai.peterstorm.inference.state-safety=pr50021-pr50287-adapted-pr50729-pr54296-jovian-pr539-adapted-plus-cpu-mixed-partition \
  --label ai.peterstorm.inference.exact-sparse-topk=pr52149-overflow-radix-deterministic-ties \
  --label ai.peterstorm.inference.kpool-tail=persistent-circular-slot-buffer \
  --label ai.peterstorm.inference.graph-mode=cudagraph-dcp2-mtp3-dense-shapes-candidate \
  --label ai.peterstorm.inference.attention-backend=b12x-mla-sparse \
  --label ai.peterstorm.inference.dcp-transport=ag-rs \
  --label ai.peterstorm.inference.mamba-dcp-layout=replicated-full-position-table \
  --label ai.peterstorm.inference.kv-cache=fp8_ds_mla \
  --label ai.peterstorm.inference.kv-cache-memory-bytes-per-gpu="$KV_CACHE_MEMORY_BYTES" \
  --label ai.peterstorm.inference.runtime-headroom=dcp2-prefill-all-gather-safe \
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
  -e VLLM_B12X_GLM_NOPE_FP8=1 \
  -e VLLM_EXL3_PREFILL_BLOCK_M=128 \
  -e VLLM_EXL3_PREFILL_TRELLIS=1 \
  -e B12X_GL53_ROUTE128_WIDE=1 \
  -e B12X_GL53_ROUTE128_HYBRID_TAIL=1 \
  -e VLLM_USE_B12X_SPARSE_INDEXER=1 \
  -e VLLM_USE_B12X_KPOOL_INDEXER=1 \
  -e VLLM_DCP_GLOBAL_TOPK=1 \
  -e VLLM_DCP_QUERY_SPLIT=0 \
  -e VLLM_DCP_TOPK_OWNER_MERGE=1 \
  -e VLLM_B12X_DCP_TOPK_OWNER_EXCHANGE=1 \
  -e VLLM_B12X_DCP_TOPK_MIN_ROWS=128 \
  -e VLLM_B12X_DCP_TOPK_MAX_ROWS="$MAX_NUM_BATCHED_TOKENS" \
  -e VLLM_B12X_DCP_A2A=1 \
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
  --decode-context-parallel-size 2 \
  --dcp-comm-backend ag_rs \
  --dtype bfloat16 \
  --kv-cache-dtype fp8_ds_mla \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --kv-cache-memory-bytes "$KV_CACHE_MEMORY_BYTES" \
  --moe-backend b12x \
  --attention-backend B12X_MLA_SPARSE \
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
  --compilation-config '{"cudagraph_mode":"FULL_AND_PIECEWISE","cudagraph_capture_sizes":[1,2,3,4,8,12,16]}' \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"greedy"}'

printf "Started multimodal FP8-DS-MLA DCP2/MTP3 359K profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v10 uses TP2/EP2/DCP2 with B12X sparse MLA, ag_rs, CUDA graphs, 359,000 context, FP8 DS MLA KV, vision, mandatory prefix caching + MTP3, replicated full-width recurrent tables, and fail-closed block writes.'
printf 'KV cache is fixed at %s bytes (3.5 GiB) per GPU so warm and cold boots preserve DCP2 prefill all-gather headroom.\n' "$KV_CACHE_MEMORY_BYTES"
printf '%s\n' 'The v10 switcher records exact KV capacity but deliberately retains restart=no until output-equivalence, mixed-traffic, and soak gates pass.'
