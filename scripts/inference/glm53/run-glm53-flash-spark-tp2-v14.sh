#!/usr/bin/env bash
# GLM-5.3 v14: the upstream Karmic Kraken beta image with the GLM Spark TP2
# preset (TP2/DCP2, MTP3, four slots, 3072-token prefill budget, 3996 MiB/GPU
# fixed KV, memory-resolved ~983K context, vision, FP8 target KV / FP32
# recurrent state, BF16 target head + private NVFP4 MTP draft head).
#
# v14 is a stock upstream deployment — no custom overlay; the checkpoint is
# pre-downloaded by download-glm53-flash-spark-tp2-v14-checkpoint.sh into the
# host hub cache (/models/hf-cache/glm53-flash-spark-tp2-v14, the same cache
# the doc's named volume would hold) and serving is offline-pinned to that
# revision. What the repository still owns:
#   - the exact image id (IMAGE_CONFIG from the pull script) and the exact
#     served model id (SERVED_MODEL_NAME overrides the preset's GLM-5.3-Flash);
#   - the workstation gates: exactly two RTX PRO 6000 Blackwell cards at the
#     declarative gpuPowerLimitWatts pin (machines/desktop/default.nix),
#     memory idle, comfyui stopped, port 8000 free;
#   - the transactional shape: --restart no here, unless-stopped only after
#     the switcher accepts the boot (the upstream doc's unless-stopped is the
#     promoted end state, not the launch-time default);
#   - no env overrides for the preset's memory contract: MAX_MODEL_LEN stays
#     unset (memory-resolved ~983K, printed at boot), KV stays
#     4190109696 bytes/GPU, slots stay 4, prefill stays 3072. The old EXL3 K4
#     switch set (VLLM_B12X_*, VLLM_DCP_GLOBAL_TOPK, TRELLIS, ROUTE128,
#     PCIE_ALLREDUCE, GLM_NOPE_*) belongs to the retired patch series and must
#     not be carried.
#
# Optional LMCache pass: CACHE_MODE=lmcache turns on the upstream RAM+disk
# prefix tier (16 GiB L1, 2 GiB init, 64 GiB disk in /cache); with
# LMCACHE_L2_ENABLED=0 the disk tier is omitted. The default is GPU-only
# prefix caching. The cache sidecar reserves API port + 10000/10001/10002.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

# Pinned by pull-glm53-flash-spark-tp2-v14-image.sh on the serving host. Until
# then the profile is unlaunchable by construction.
IMAGE_CONFIG="sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a"
PULL_REF="ghcr.io/local-inference-lab/vllm:karmic-kraken-beta"
PRESET="glm53-spark-tp2"
CHECKPOINT="local-inference-lab/GLM-5.3-Flash-NVFP4-Spark"
NAME="glm53-flash-spark-tp2-v14"
SERVED_MODEL="glm-5.3-flash-spark-tp2-v14"
HF_CACHE_HOST="${HF_CACHE_HOST:-/models/hf-cache/glm53-flash-spark-tp2-v14}"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-spark-tp2-v14}"
GPU_ORDER="${GPU_ORDER:-0,1}"
# Pinned by download-glm53-flash-spark-tp2-v14-checkpoint.sh on the serving
# host; the offline gate refuses to serve anything else.
MODEL_REVISION="a608241037e4c2565356bff7ca293f2133888f88"
CACHE_MODE="${CACHE_MODE:-vram}"
LMCACHE_L1_GB="${LMCACHE_L1_GB:-16}"
LMCACHE_L1_INIT_GB="${LMCACHE_L1_INIT_GB:-2}"
LMCACHE_L2_ENABLED="${LMCACHE_L2_ENABLED:-1}"
LMCACHE_L2_GB="${LMCACHE_L2_GB:-64}"
LMCACHE_MAX_CPU_WORKERS="${LMCACHE_MAX_CPU_WORKERS:-4}"
LMCACHE_MAX_GPU_WORKERS="${LMCACHE_MAX_GPU_WORKERS:-2}"
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
case "$CACHE_MODE" in
  vram | lmcache) ;;
  *) echo "error: CACHE_MODE must be vram (GPU-only, upstream default) or lmcache (RAM+disk prefix tier)" >&2; exit 2 ;;
esac
case "$LMCACHE_L2_ENABLED" in
  0 | 1) ;;
  *) echo "error: LMCACHE_L2_ENABLED must be 0 or 1" >&2; exit 2 ;;
esac
integer_in_range LMCACHE_L1_GB "$LMCACHE_L1_GB" 1 32
integer_in_range LMCACHE_L1_INIT_GB "$LMCACHE_L1_INIT_GB" 1 "$LMCACHE_L1_GB"
integer_in_range LMCACHE_L2_GB "$LMCACHE_L2_GB" 8 128
integer_in_range LMCACHE_MAX_CPU_WORKERS "$LMCACHE_MAX_CPU_WORKERS" 1 16
integer_in_range LMCACHE_MAX_GPU_WORKERS "$LMCACHE_MAX_GPU_WORKERS" 0 4
# The old overlay switch set must not be carried into the upstream image.
for switch in VLLM_B12X_FP8_KV VLLM_B12X_GLM_NOPE_NVFP4 VLLM_DCP_GLOBAL_TOPK \
  VLLM_USE_B12X_DCP_A2A TRELLIS ROUTE128 PCIE_ALLREDUCE GLM_NOPE_FP8 \
  VLLM_MAMBA_STATE_PROTECT VLLM_MAMBA_ALIGN_CAP_LEGACY; do
  if [ -n "${!switch:-}" ]; then
    echo "error: $switch belongs to the retired EXL3 K4 patch series; unset it for v14" >&2
    exit 2
  fi
done
if [ "$IMAGE_CONFIG" = "unrecorded" ]; then
  echo "error: the v14 image id is not recorded; pull it with scripts/inference/glm53/pull-glm53-flash-spark-tp2-v14-image.sh and record the image id as IMAGE_CONFIG in ${0##*/}" >&2
  exit 2
fi
[[ "$IMAGE_CONFIG" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "error: IMAGE_CONFIG must be 'unrecorded' or the recorded image id (sha256:<64 hex>)" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE_CONFIG" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned GLM v14 image is absent; run scripts/inference/glm53/pull-glm53-flash-spark-tp2-v14-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local GLM v14 image id is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
tag_binding="$(docker image inspect "$PULL_REF" --format '{{.Id}}' 2>/dev/null || true)"
[ "$tag_binding" = "$IMAGE_CONFIG" ] || {
  echo "error: $PULL_REF now resolves to ${tag_binding:-<absent>}, not the pinned $IMAGE_CONFIG; re-pin with the pull script before serving" >&2
  exit 1
}

# CPU-only launch-plan proof: the pinned image must still resolve the spark
# preset AND the repository's served model id for this exact image id.
plan_proof="$(docker run --rm --runtime runc --network none \
  -e PRESET="$PRESET" -e SERVED_MODEL_NAME="$SERVED_MODEL" \
  "$IMAGE_CONFIG" --print-config 2>/dev/null)" || {
  echo "error: --print-config failed for the pinned v14 image" >&2
  exit 1
}
if ! jq -e --arg model "$SERVED_MODEL" '
  .profile == "glm53-flash"
  and .hardware == "rtx-pro-6000-pcie"
  and .settings["served-model-name"].value == $model
  and .settings["tensor-parallel-size"].value == 2
  and .settings["decode-context-parallel-size"].value == 2
  and .settings["kv-cache-memory-bytes"].value == 4190109696
' <<<"$plan_proof" >/dev/null 2>&1; then
  echo "error: pinned image no longer resolves the documented v14 launch plan" >&2
  exit 1
fi

# The expected wattage is the declarative pin (gpuPowerLimitWatts in
# machines/desktop/default.nix), not a hardcoded constant: the fan/thermal
# retunes retune it in one place and this gate follows. The dotfiles root is
# walked up from this script, anchored on the config itself, so relocation
# cannot drift the path; missing or unpinned config fails closed.
NIX_GPU_CONFIG=''
WALK_ROOT="$SCRIPT_DIR"
while [[ -z "$NIX_GPU_CONFIG" && "$WALK_ROOT" != "/" ]]; do
  if [[ -f "$WALK_ROOT/machines/desktop/default.nix" ]]; then
    NIX_GPU_CONFIG="$WALK_ROOT/machines/desktop/default.nix"
  else
    WALK_ROOT="$(dirname "$WALK_ROOT")"
  fi
done
[[ -n "$NIX_GPU_CONFIG" ]] || {
  echo "error: no machines/desktop/default.nix found above $SCRIPT_DIR" >&2
  exit 1
}
DECLARED_GPU_WATTS="$(sed -nE 's/^[[:space:]]*gpuPowerLimitWatts = ([0-9]+);$/\1/p' "$NIX_GPU_CONFIG" | tail -1)"
[[ -n "$DECLARED_GPU_WATTS" ]] || {
  echo "error: gpuPowerLimitWatts is not pinned to an integer in $NIX_GPU_CONFIG" >&2
  exit 1
}

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
  awk -v actual="$power_limit" -v declared="$DECLARED_GPU_WATTS" \
    'BEGIN { exit !(actual >= declared - 0.5 && actual <= declared + 0.5) }' || {
      echo "error: GPU $index power limit is ${power_limit} W; declarative config pins ${DECLARED_GPU_WATTS} W" >&2
      exit 1
    }
done

# Offline checkpoint gate: the run script serves only the pre-downloaded
# revision. The marker is written by the download script after
# snapshot_download(local_files_only=True) succeeds.
if [ ! -r "$HF_CACHE_HOST/.download-complete" ]; then
  echo "error: checkpoint cache is absent at $HF_CACHE_HOST; run scripts/inference/glm53/download-glm53-flash-spark-tp2-v14-checkpoint.sh" >&2
  exit 1
fi
checkpoint_marker="$(<"$HF_CACHE_HOST/.download-complete")"
[ "$checkpoint_marker" = "$CHECKPOINT $MODEL_REVISION" ] || {
  echo "error: checkpoint marker is '$checkpoint_marker', expected '$CHECKPOINT $MODEL_REVISION'" >&2
  exit 1
}
snapshot_dir="$HF_CACHE_HOST/hub/models--$(printf '%s' "$CHECKPOINT" | tr '/' '--')/snapshots/$MODEL_REVISION"
[ -f "$snapshot_dir/config.json" ] || {
  echo "error: pinned snapshot is incomplete at $snapshot_dir" >&2
  exit 1
}

inference_remove_container_if_present "$NAME"
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  echo "error: host port 8000 is already listening; use the v14 switcher when ready to replace the active profile" >&2
  exit 1
fi

if [ "$CACHE_MODE" = lmcache ]; then
  # The cache service reserves API port + 10000/10001/10002 (8000 -> 18000-18002).
  for port in 18000 18001 18002; do
    if ss -H -ltn | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
      echo "error: LMCache sidecar port $port is already listening" >&2
      exit 1
    fi
  done
  shm_free="$(awk '/\/dev\/shm/ {print $4}' <(df -B1 /dev/shm 2>/dev/null) 2>/dev/null || true)"
  [[ -n "$shm_free" ]] || {
    echo "error: /dev/shm is unavailable; LMCache needs the pinned L1 arena" >&2
    exit 1
  }
  ((shm_free >= (LMCACHE_L1_GB + 2) * 1024 * 1024 * 1024)) || {
    echo "error: /dev/shm has ${shm_free} bytes; LMCache L1=${LMCACHE_L1_GB}GiB plus transfer buffers does not fit (--shm-size does not grow host /dev/shm under --ipc host)" >&2
    exit 1
  }
  mem_available_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  ((mem_available_kb >= (LMCACHE_L1_GB + 4) * 1024 * 1024)) || {
    echo "error: host RAM is short for LMCache; MemAvailable is ${mem_available_kb} KiB" >&2
    exit 1
  }
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/flash-spark-tp2-v14.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF
# The checkpoint is public, but a saved local token removes any rate/gating
# surprise on the first download; it stays out of the environment otherwise.
if [ -r "$INFERENCE_OPERATOR_HOME/.cache/huggingface/token" ]; then
  printf 'HF_TOKEN=%s\n' "$(<"$INFERENCE_OPERATOR_HOME/.cache/huggingface/token")" >>"$ENVFILE"
fi

if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 v14 upstream spark-preset preflight: PASS"
  echo "Capacity is intentionally not predicted: the preset resolves max-model-len from memory (upstream reports ~983k GPU-only; 924k with LMCache). The switcher records the exact boot value."
  exit 0
fi

cache_env=()
if [ "$CACHE_MODE" = vram ]; then
  cache_env+=(-e CACHE_MODE=vram)
else
  cache_env=(
    -e CACHE_MODE=lmcache
    -e LMCACHE_L1_GB="$LMCACHE_L1_GB"
    -e LMCACHE_L1_INIT_GB="$LMCACHE_L1_INIT_GB"
    -e LMCACHE_L2_ENABLED="$LMCACHE_L2_ENABLED"
    -e LMCACHE_L2_GB="$LMCACHE_L2_GB"
    -e LMCACHE_MAX_CPU_WORKERS="$LMCACHE_MAX_CPU_WORKERS"
    -e LMCACHE_MAX_GPU_WORKERS="$LMCACHE_MAX_GPU_WORKERS"
  )
fi

docker run -d --init \
  --restart no \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=glm53-flash-spark-tp2-v14 \
  --label ai.peterstorm.inference.image-config="$IMAGE_CONFIG" \
  --label ai.peterstorm.inference.checkpoint="$CHECKPOINT@$MODEL_REVISION" \
  --label ai.peterstorm.inference.checkpoint-cache=host-offline-pinned \
  --label ai.peterstorm.inference.preset="$PRESET" \
  --label ai.peterstorm.inference.hardware-profile=rtx-pro-6000-pcie \
  --label ai.peterstorm.inference.speculation=mtp3 \
  --label ai.peterstorm.inference.parallelism=tp2-dcp2 \
  --label ai.peterstorm.inference.kv-cache=fp8-3996mib-per-gpu-fixed \
  --label ai.peterstorm.inference.vision=enabled-no-admission-cap \
  --label ai.peterstorm.inference.cache-mode="$CACHE_MODE" \
  --gpus "\"device=$GPU_ORDER\"" \
  --network host \
  --ipc host \
  --shm-size 32g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864:67108864 \
  --security-opt seccomp=unconfined \
  --env-file "$ENVFILE" \
  -v "$HF_CACHE_HOST:/root/.cache/huggingface" \
  -v "$CACHE_HOST:/cache" \
  -e PRESET="$PRESET" \
  -e PORT=8000 \
  -e SERVED_MODEL_NAME="$SERVED_MODEL" \
  -e MODEL_REVISION="$MODEL_REVISION" \
  -e HF_HUB_OFFLINE=1 \
  "${cache_env[@]}" \
  "$IMAGE_CONFIG"

printf "Started upstream karmic-kraken GLM Spark TP2 profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v14 serves the pre-downloaded checkpoint offline: '"$CHECKPOINT@$MODEL_REVISION"' from the host hub cache; the engine cannot fetch anything else.'
printf '%s\n' 'Served model id: '"$SERVED_MODEL"'. The preset resolves ~983k text tokens (GPU-only) or ~924k (LMCache); the switcher records the exact boot limit.'
printf '%s\n' 'Keep PRESET, KV, slots and prefill unchanged: the memory contract was validated upstream against those exact values.'
