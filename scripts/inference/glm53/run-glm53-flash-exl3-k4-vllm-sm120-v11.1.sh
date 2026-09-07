#!/usr/bin/env bash
# GLM-5.3 v11.1: upstream-core-port r2.1 — v11 plus the admission deadlock fix.
#
# Same serving shape as v11 (native FP8 KV, vision, MTP3, TP2/EP/DCP2 a2a); the
# image differs only in the three engine-core files r2.1 changes. What r2.1
# adds to the operator surface:
#   VLLM_MAMBA_STATE_PROTECT stays ON at upstream's 16: with the fix the reserve
#     can no longer starve admission, and it is what keeps a concurrent whale
#     from stripping a fresh session's cached states.
#   VLLM_MAMBA_STATE_PROTECT_AGE (default 128) bounds how many scheduling
#     attempts a request may be blocked SOLELY by that reserve before it is
#     admitted on demand alone (0 = never, i.e. r2's starvable behaviour).
#   VLLM_MAMBA_ALIGN_CAP_LEGACY is the kill-switch that restores r2's inflated
#     null-slot billing — the deadlock — and is deliberately never set here.
# r2.1 also removes r2's Fix B prefill chunk cap upstream; decode protection is
# now --prefill-schedule-interval alone, so this profile must re-qualify under
# the mixed-traffic gate before promotion.
#
# The v11 env note still applies: v10's VLLM_DCP_GLOBAL_TOPK / TRELLIS /
# ROUTE128 / PCIE_ALLREDUCE / GLM_NOPE_FP8 switches belong to the retired patch
# series and are not carried. VLLM_B12X_FP8_KV=1 selects the validated 528-byte
# GLM_NOPE record and VLLM_B12X_GLM_NOPE_NVFP4 stays unset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

# Recorded from pull-glm53-flash-exl3-k4-vllm-sm120-v11.1-image.sh's derived_id
# on the serving host. Until then the profile is unlaunchable by construction.
IMAGE_CONFIG="unrecorded"
IMAGE="$IMAGE_CONFIG"
MODEL_HOST="${MODEL_HOST:-$HOME/models/GLM-5.3-Flash-EXL3-K4-v1}"
MODEL_CONTAINER="/model"
# A fresh cache directory: v11's carries torch/triton artifacts compiled against
# the r2 tree and, from the 2026-09-06 diagnosis, the /cache/.diff-dump probe
# marker. Nothing in it is worth inheriting.
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v11.1}"
NAME="glm53-flash-exl3-k4-vllm-sm120-v11.1"
SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1"
UPSTREAM_COMMIT="832e6000120148f82c64acaecc56b6f96c27e6e2"

GPU_ORDER="${GPU_ORDER:-1,0}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-359000}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.987}"
# Dtype-coupled: upstream documents 17,920 for FP8 and 15,616 for nvfp4. This
# profile is FP8-only, so the FP8 value is the only legal one.
PREFIX_CACHE_RETENTION_INTERVAL="${PREFIX_CACHE_RETENTION_INTERVAL:-17920}"
MAMBA_STATE_PROTECT="${MAMBA_STATE_PROTECT:-16}"
MAMBA_STATE_PROTECT_AGE="${MAMBA_STATE_PROTECT_AGE:-128}"
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
integer_in_range MAMBA_STATE_PROTECT "$MAMBA_STATE_PROTECT" 0 64
integer_in_range MAMBA_STATE_PROTECT_AGE "$MAMBA_STATE_PROTECT_AGE" 1 100000
[ "$PREFIX_CACHE_RETENTION_INTERVAL" = 17920 ] || {
  echo "error: FP8 KV couples the retention interval to 17920 (15616 is the nvfp4 value)" >&2
  exit 2
}
[ -z "${VLLM_MAMBA_ALIGN_CAP_LEGACY:-}" ] || {
  echo "error: VLLM_MAMBA_ALIGN_CAP_LEGACY restores the r2 admission deadlock; unset it" >&2
  exit 2
}
[[ "$IMAGE_CONFIG" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "error: the v11.1 image id is not recorded; build it with scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v11.1-image.sh and record derived_id as IMAGE_CONFIG in ${0##*/}" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned GLM v11.1 image is absent; run scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v11.1-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local GLM v11.1 image config is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
overlay_release="$(docker image inspect "$IMAGE" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.release"}}')"
[ "$overlay_release" = r2.1 ] || {
  echo "error: image does not carry the upstream-core-port r2.1 overlay (label: ${overlay_release:-<missing>})" >&2
  exit 1
}
overlay_commit="$(docker image inspect "$IMAGE" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.commit"}}')"
[ "$overlay_commit" = "$UPSTREAM_COMMIT" ] || {
  echo "error: image records upstream commit ${overlay_commit:-<missing>}, expected $UPSTREAM_COMMIT" >&2
  exit 1
}
MODEL_HOST="$MODEL_HOST" "$SCRIPT_DIR/verify-glm53-flash-exl3-k4-v1.sh"
if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 v11.1 upstream-core-port r2.1 native-FP8 multimodal preflight: PASS"
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
  echo "error: host port 8000 is already listening; use the v11.1 switcher when ready to replace the active profile" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/exl3-k4-vllm-sm120-v11.1.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"
# The overlay's diagnostic probes (GDN-IDX, ALIGN-CLAMP, KDA-STATE, H2D dumps)
# arm on this marker's existence alone, sync the GPU every step, and log
# thousands of lines per minute. A serving boot must never inherit one.
[ ! -e "$CACHE_HOST/.diff-dump" ] || {
  echo "error: $CACHE_HOST/.diff-dump arms the overlay's per-step diagnostic probes; remove it before serving" >&2
  exit 1
}

docker run -d --init \
  --restart no \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=glm53-flash-exl3-k4-vllm-sm120-v11.1 \
  --label ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v11.1-boot \
  --label ai.peterstorm.inference.checkpoint=brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51 \
  --label ai.peterstorm.inference.upstream-core-port="legend-r2.1-$UPSTREAM_COMMIT" \
  --label ai.peterstorm.inference.admission-deadlock-fix=r2.1-0004-0005-0006 \
  --label ai.peterstorm.inference.speculation=mtp3 \
  --label ai.peterstorm.inference.prefix-cache=mandatory \
  --label ai.peterstorm.inference.attention-backend=b12x-mla-sparse \
  --label ai.peterstorm.inference.dcp-transport=a2a \
  --label ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b \
  --label ai.peterstorm.inference.prefix-cache-retention-interval="$PREFIX_CACHE_RETENTION_INTERVAL" \
  --label ai.peterstorm.inference.mamba-state-protect="$MAMBA_STATE_PROTECT" \
  --label ai.peterstorm.inference.mamba-state-protect-age="$MAMBA_STATE_PROTECT_AGE" \
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
  -e VLLM_MAMBA_STATE_PROTECT_AGE="$MAMBA_STATE_PROTECT_AGE" \
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

printf "Started upstream-core-port r2.1 native-FP8 multimodal profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v11.1 is v11 (legend r2) plus upstream 832e6000, the admission deadlock fix: 0004 align cap bills the real footprint, 0005 reserve aging escape, 0006 unconditional deferred-free drain. r2 wedged (running=0, waiting=N, KV 0%) whenever a long session headed the waiting queue.'
printf '%s\n' 'KV is native fp8_ds_mla on the validated 528-byte GLM_NOPE record (VLLM_B12X_FP8_KV=1); the mamba-state reserve stays on at 16 with an aging escape of 128 attempts; vision stays on through the multimodal chat template.'
printf '%s\n' 'r2.1 removed the Fix B prefill chunk cap upstream, so decode protection is --prefill-schedule-interval alone; the v11.1 switcher records exact KV capacity and retains restart=no until equivalence, mixed-traffic, long-session, and soak gates pass.'
