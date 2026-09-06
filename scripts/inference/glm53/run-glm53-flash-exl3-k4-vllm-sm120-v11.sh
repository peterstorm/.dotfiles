#!/usr/bin/env bash
# GLM-5.3 v11: upstream-core-port r2 with native FP8 KV and vision.
#
# The environment and flags below are the upstream r2 qualified shape, not v10's.
# v10's env set (VLLM_DCP_GLOBAL_TOPK, VLLM_B12X_DCP_TOPK_OWNER_EXCHANGE,
# VLLM_EXL3_PREFILL_TRELLIS, B12X_GL53_ROUTE128_*, VLLM_ENABLE_PCIE_ALLREDUCE,
# VLLM_B12X_GLM_NOPE_FP8, ...) belongs to our v9/v10 patch series, which this
# image replaces; carrying those switches into a tree that no longer implements
# them would be cargo cult. FP8 KV is gated by the upstream name here:
# VLLM_B12X_FP8_KV=1 selects the validated 528-byte GLM_NOPE record, and
# VLLM_B12X_GLM_NOPE_NVFP4 is deliberately left unset so nvfp4 cannot be chosen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="sha256:3d0ace8a8e5fc48eaf74e78d8030b6de8a949ba9b0041266d92056052dd90d1d"
IMAGE_CONFIG="sha256:3d0ace8a8e5fc48eaf74e78d8030b6de8a949ba9b0041266d92056052dd90d1d"
MODEL_HOST="${MODEL_HOST:-$HOME/models/GLM-5.3-Flash-EXL3-K4-v1}"
MODEL_CONTAINER="/model"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v11}"
NAME="glm53-flash-exl3-k4-vllm-sm120-v11"
SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11"

GPU_ORDER="${GPU_ORDER:-1,0}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-359000}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.987}"
# Dtype-coupled: upstream documents 17,920 for FP8 and 15,616 for nvfp4. This
# profile is FP8-only, so the FP8 value is the only legal one.
PREFIX_CACHE_RETENTION_INTERVAL="${PREFIX_CACHE_RETENTION_INTERVAL:-17920}"
MAMBA_STATE_PROTECT="${MAMBA_STATE_PROTECT:-16}"
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
integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 16
integer_in_range MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS" 1 2048
[ "$PREFIX_CACHE_RETENTION_INTERVAL" = 17920 ] || {
  echo "error: FP8 KV couples the retention interval to 17920 (15616 is the nvfp4 value)" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned GLM v11 image is absent; run scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v11-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local GLM v11 image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
overlay_release="$(docker image inspect "$IMAGE" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.release"}}')"
[ "$overlay_release" = r2 ] || {
  echo "error: image does not carry the upstream-core-port r2 overlay (label: ${overlay_release:-<missing>})" >&2
  exit 1
}
MODEL_HOST="$MODEL_HOST" "$SCRIPT_DIR/verify-glm53-flash-exl3-k4-v1.sh"
if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 v11 upstream-core-port r2 native-FP8 multimodal preflight: PASS"
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
  echo "error: host port 8000 is already listening; use the v11 switcher when ready to replace the active profile" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/exl3-k4-vllm-sm120-v11.env"
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
  --label ai.peterstorm.inference.profile=glm53-flash-exl3-k4-vllm-sm120-v11 \
  --label ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v11-boot \
  --label ai.peterstorm.inference.checkpoint=brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51 \
  --label ai.peterstorm.inference.upstream-core-port=legend-r2-e65b2012d4ead12c86bd03f7e435ebace3ed3ae2 \
  --label ai.peterstorm.inference.speculation=mtp3 \
  --label ai.peterstorm.inference.prefix-cache=mandatory \
  --label ai.peterstorm.inference.attention-backend=b12x-mla-sparse \
  --label ai.peterstorm.inference.dcp-transport=a2a \
  --label ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b \
  --label ai.peterstorm.inference.prefix-cache-retention-interval="$PREFIX_CACHE_RETENTION_INTERVAL" \
  --label ai.peterstorm.inference.mamba-state-protect="$MAMBA_STATE_PROTECT" \
  --label ai.peterstorm.inference.vision=enabled \
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
  -e OMP_NUM_THREADS=2 \
  -e VLLM_ENGINE_READY_TIMEOUT_S=3600 \
  -e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0 \
  -e VLLM_DEBUG_KDA_INPUTS=0 \
  -e VLLM_USE_B12X_DCP_A2A=1 \
  -e VLLM_B12X_FP8_KV=1 \
  -e VLLM_MAMBA_STATE_PROTECT="$MAMBA_STATE_PROTECT" \
  -e VLLM_PREFIX_CACHE_RETENTION_INTERVAL="$PREFIX_CACHE_RETENTION_INTERVAL" \
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
  --enable-expert-parallel \
  --decode-context-parallel-size 2 \
  --dcp-comm-backend a2a \
  --disable-custom-all-reduce \
  --dtype bfloat16 \
  --load-format safetensors \
  --moe-backend b12x \
  --attention-backend B12X_MLA_SPARSE \
  --kv-cache-dtype fp8_ds_mla \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --enable-chunked-prefill \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --reasoning-parser glm45 \
  --tool-call-parser glm47 \
  --generation-config "$MODEL_CONTAINER" \
  --chat-template /opt/glm53/chat_template.multimodal.jinja \
  --mm-encoder-attn-backend TORCH_SDPA \
  --limit-mm-per-prompt '{"image":4,"video":0}' \
  --prefill-schedule-interval 8 \
  --kda-prefill-backend triton \
  --compilation-config '{"cudagraph_capture_sizes":[1,2,4,8,16,24,32,40,48,56,64]}' \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'

printf "Started upstream-core-port r2 native-FP8 multimodal profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v11 replaces the v9/v10 patch series with the legend upstream-core port r2: upstream engine core, sparse-MLA layer-view aliasing fix, b12x record-walk stride fix, H2D lifetime fixes, indexer restore, gather clamps, rejection-sampler padding mask, scheduler Fix A/B, kvcache 0001/0002, attn 0002, cache-wipe reserve, and int64 Triton fixes.'
printf '%s\n' 'KV is native fp8_ds_mla on the validated 528-byte GLM_NOPE record (VLLM_B12X_FP8_KV=1); vision stays on through the multimodal chat template, which also carries the thinking-disable fix.'
printf '%s\n' 'The v11 switcher records exact KV capacity and retains restart=no until equivalence, mixed-traffic, and soak gates pass.'
