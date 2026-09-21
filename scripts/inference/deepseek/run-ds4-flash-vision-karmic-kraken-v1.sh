#!/usr/bin/env bash
# DeepSeek V4 Flash Vision — Karmic Kraken beta ds4-vision profile (v1).
#
# Serves deepseek-ai/DeepSeek-V4-Flash-Vision-Exp @ 6821d6ad... from the
# upstream *versioned* Karmic Kraken beta image
# (karmic-kraken-beta-20260920-443d9f815c57d23b, digest sha256:55e477ad...) with
# PROFILE=ds4-vision: TP2/DCP1, DSpark K3, four slots, 4096-token prefill
# budget, fp8 target KV / block 256, B12X attention + MoE, instanttensor load,
# 1,048,576-token context (the qualified benchmark arm), GPU-only prefix cache.
#
# The deployment contract is the upstream ds4-vision profile plus the exact
# environment the Karmic Kraken benchmark's Vision arm set
# (benchmarks/karmic-kraken-serving.md samples JSON, kk.docker_argv); the
# native sampling override stays at the benchmark arm's
# {"temperature":1.0,"top_p":1.0} (the profile preset default is top-p 0.95;
# clear GEN_OVERRIDES to serve the preset default).
#
# What the repository owns (mirrors the v14 upstream-profile pattern):
#   - the exact image id (IMAGE_CONFIG, pinned by the pull script) and the
#     exact served model id (SERVED_MODEL_NAME overrides the preset's
#     DeepSeek-V4-Flash-Vision-Exp so Pi/catalog keep deepseek-v4-flash-vision);
#   - the workstation gates: exactly two RTX PRO 6000 Blackwell cards at the
#     declarative gpuPowerLimitWatts pin (machines/desktop/default.nix),
#     memory idle, comfyui stopped, port 8000 free;
#   - offline serving: the checkpoint is pre-downloaded by
#     download-ds4-flash-vision-karmic-kraken-v1-checkpoint.sh into the host
#     hub cache (/models/hf-cache/ds4-flash-vision-karmic-kraken-v1) and
#     pinned with HF_HUB_OFFLINE=1 + MODEL_REVISION;
#   - the transactional shape: --restart no here, unless-stopped only after
#     the switcher accepts the boot;
#   - a fail-closed CUDA runtime probe (cuBLAS + cuDNN on the first GPU, real
#     deterministic two-GPU NCCL allreduce) before the serving container starts.
#
# The upstream Max-Q measurements (C1 193.9 tok/s, C4 401.4 tok/s, 32K prefill
# 9,182 tok/s, 1,291,085 logical KV tokens) were taken at a 325 W Max-Q power
# limit; this workstation pins 400 W (declarative), so absolute numbers differ
# while the geometry (TP2, two RTX PRO 6000 Blackwell cards) is identical.
#
# Optional LMCache pass: CACHE_MODE=lmcache turns on the upstream RAM+disk
# prefix tier (16 GiB L1, 2 GiB init, 64 GiB disk in /cache); with
# LMCACHE_L2_ENABLED=0 the disk tier is omitted. The default is GPU-only
# prefix caching (the benchmark arm's configuration). The cache sidecar
# reserves API port + 10000/10001/10002.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

# Pinned by pull-ds4-flash-vision-karmic-kraken-v1-image.sh on the serving
# host (the versioned Karmic Kraken beta release, repo digest
# sha256:55e477ad62ae15a77c9b869e8fb8e2d958f6edcc4d95e306adfa89dee9ed19df).
IMAGE_CONFIG="sha256:83f00757ff18f3c3c12de291319b1a3a5496056a3873834d0994160828a3c6ee"
PULL_REF="ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20260920-443d9f815c57d23b"
PROFILE="ds4-vision"
CHECKPOINT="deepseek-ai/DeepSeek-V4-Flash-Vision-Exp"
NAME="ds4-flash-vision-karmic-kraken-v1"
SERVED_MODEL="deepseek-v4-flash-vision"
HF_CACHE_HOST="${HF_CACHE_HOST:-/models/hf-cache/ds4-flash-vision-karmic-kraken-v1}"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/ds4-flash-vision-karmic-kraken-v1}"
GPU_ORDER="${GPU_ORDER:-0,1}"
# The revision the Karmic Kraken benchmark ran; pinned by the checkpoint
# download script, and the offline gate refuses to serve anything else.
MODEL_REVISION="6821d6ad3681a4b137b066b76094fa82ebd0a380"
# Karmic Kraken benchmark-arm memory/context contract (all env-overrideable,
# defaults are the qualified values):
MAX_MODEL_LEN="${MAX_MODEL_LEN:-1048576}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.975}"
# Benchmark-arm sampling override; empty string serves the profile default
# (temperature 1, top-p 0.95).
GEN_OVERRIDES="${GEN_OVERRIDES:-{\"temperature\":1.0,\"top_p\":1.0}}"
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
integer_in_range MAX_MODEL_LEN "$MAX_MODEL_LEN" 8192 1048576
integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 16
integer_in_range MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS" 1024 4096
integer_in_range LMCACHE_L1_GB "$LMCACHE_L1_GB" 1 32
integer_in_range LMCACHE_L1_INIT_GB "$LMCACHE_L1_INIT_GB" 1 "$LMCACHE_L1_GB"
integer_in_range LMCACHE_L2_GB "$LMCACHE_L2_GB" 8 128
integer_in_range LMCACHE_MAX_CPU_WORKERS "$LMCACHE_MAX_CPU_WORKERS" 1 16
integer_in_range LMCACHE_MAX_GPU_WORKERS "$LMCACHE_MAX_GPU_WORKERS" 0 4
case "$CACHE_MODE" in
  vram | lmcache) ;;
  *) echo "error: CACHE_MODE must be vram (GPU-only, benchmark arm) or lmcache (RAM+disk prefix tier)" >&2; exit 2 ;;
esac
case "$LMCACHE_L2_ENABLED" in
  0 | 1) ;;
  *) echo "error: LMCACHE_L2_ENABLED must be 0 or 1" >&2; exit 2 ;;
esac
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" \
    'BEGIN { exit !(value >= 0.90 && value <= 0.98) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be in [0.90, 0.98]" >&2
  exit 2
fi
if [ -n "$GEN_OVERRIDES" ]; then
  jq -e . <<<"$GEN_OVERRIDES" >/dev/null 2>&1 || {
    echo "error: GEN_OVERRIDES must be empty or valid JSON" >&2
    exit 2
  }
fi
if [ "$IMAGE_CONFIG" = "unrecorded" ]; then
  echo "error: the image id is not recorded; pull it with scripts/inference/deepseek/pull-ds4-flash-vision-karmic-kraken-v1-image.sh and record the image id as IMAGE_CONFIG in ${0##*/}" >&2
  exit 2
fi
[[ "$IMAGE_CONFIG" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "error: IMAGE_CONFIG must be 'unrecorded' or the recorded image id (sha256:<64 hex>)" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE_CONFIG" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned DS4 Vision KK image is absent; run scripts/inference/deepseek/pull-ds4-flash-vision-karmic-kraken-v1-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local DS4 Vision KK image id is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
tag_binding="$(docker image inspect "$PULL_REF" --format '{{.Id}}' 2>/dev/null || true)"
[ "$tag_binding" = "$IMAGE_CONFIG" ] || {
  echo "error: $PULL_REF now resolves to ${tag_binding:-<absent>}, not the pinned $IMAGE_CONFIG; re-pin with the pull script before serving" >&2
  exit 1
}

# CPU-only launch-plan proof: the pinned image must still resolve the
# ds4-vision profile AND the repository's overrides (served model id, offline
# revision pin, benchmark-arm memory contract, native sampling override) for
# this exact image id and this exact environment surface.
plan_proof_args=(--rm --runtime runc --network none
  -e PROFILE="$PROFILE" -e HARDWARE_PROFILE=rtx-pro-6000-pcie
  -e TP=2 -e DCP=1 -e PORT=8000 -e SERVED_MODEL_NAME="$SERVED_MODEL"
  -e MODEL_REVISION="$MODEL_REVISION"
  -e MAX_MODEL_LEN="$MAX_MODEL_LEN" -e MAX_NUM_SEQS="$MAX_NUM_SEQS"
  -e MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS"
  -e GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION"
  -e OMP_NUM_THREADS=2 -e VLLM_USE_BREAKABLE_CUDAGRAPH=0
  -e NCCL_SOCKET_IFNAME=lo -e GLOO_SOCKET_IFNAME=lo
  -e CACHE_MODE="$CACHE_MODE")
plan_proof_native=(--override-generation-config '{"temperature":1.0,"top_p":1.0}')
if [ -z "$GEN_OVERRIDES" ]; then
  plan_proof_native=()
elif [ "$GEN_OVERRIDES" != '{"temperature":1.0,"top_p":1.0}' ]; then
  plan_proof_native=(--override-generation-config "$GEN_OVERRIDES")
fi
plan_proof="$(docker run "${plan_proof_args[@]}" \
  "$IMAGE_CONFIG" --print-config "${plan_proof_native[@]}" 2>/dev/null)" || {
  echo "error: --print-config failed for the pinned DS4 Vision KK image" >&2
  exit 1
}
plan_assert() {
  local description="$1" filter="$2"
  shift 2
  if ! jq -e "$filter" "$@" <<<"$plan_proof" >/dev/null 2>&1; then
    echo "error: the pinned image no longer resolves the documented launch plan: $description" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$description"
}
plan_assert 'profile and hardware resolve' \
  '.profile == "ds4-vision" and .hardware == "rtx-pro-6000-pcie"'
plan_assert 'served model id is the repository id' \
  '.settings["served-model-name"].value == $model and .settings["served-model-name"].source == "environment:SERVED_MODEL_NAME"' \
  --arg model "$SERVED_MODEL"
plan_assert 'revision is the offline-pinned benchmark revision' \
  '.settings.revision.value == $rev and .settings.revision.source == "environment:MODEL_REVISION" and .settings["speculative-config"].value.revision == $rev and .settings["speculative-config"].value.num_speculative_tokens == 3' \
  --arg rev "$MODEL_REVISION"
plan_assert 'benchmark-arm context/slots/budget/utilization resolve from the environment' \
  '.settings["max-model-len"].value == ($mml | tonumber) and .settings["max-model-len"].source == "environment:MAX_MODEL_LEN" and .settings["max-num-seqs"].value == ($mns | tonumber) and .settings["max-num-seqs"].source == "environment:MAX_NUM_SEQS" and .settings["max-num-batched-tokens"].value == ($mnbt | tonumber) and .settings["max-num-batched-tokens"].source == "environment:MAX_NUM_BATCHED_TOKENS" and .settings["cache-object-tokens"].value == ($mnbt | tonumber) and (.settings["gpu-memory-utilization"].value | tostring) == $gmu and .settings["gpu-memory-utilization"].source == "environment:GPU_MEMORY_UTILIZATION"' \
  --arg mml "$MAX_MODEL_LEN" --arg mns "$MAX_NUM_SEQS" --arg mnbt "$MAX_NUM_BATCHED_TOKENS" --arg gmu "$GPU_MEMORY_UTILIZATION"
plan_assert 'TP2/DCP1 and GPU-only cache mode resolve' \
  '.settings["tensor-parallel-size"].value == 2 and .settings["decode-context-parallel-size"].value == 1 and .settings["cache-mode"].value == $cache_mode' \
  --arg cache_mode "$CACHE_MODE"
if [ -n "$GEN_OVERRIDES" ]; then
  plan_assert 'sampling override resolves from the native argument' \
    --argjson gen "$GEN_OVERRIDES" \
    '.settings["override-generation-config"].value == $gen and .settings["override-generation-config"].source == "cli"'
else
  plan_assert 'sampling resolves to the profile default with no native override' \
    '.settings["override-generation-config"].value.temperature == 1.0 and .settings["override-generation-config"].value.top_p == 0.95 and .settings["override-generation-config"].source == "model:ds4-vision"'
fi
plan_assert 'plan status is implemented' '.status == "implemented"'

# Offline checkpoint gate: the run script serves only the pre-downloaded
# revision. The marker is written by the download script after
# snapshot_download(local_files_only=True) and metadata-hash verification
# succeed. Static by design: both preflight and launch require it.
if [ ! -r "$HF_CACHE_HOST/.download-complete" ]; then
  echo "error: checkpoint cache is absent at $HF_CACHE_HOST; run scripts/inference/deepseek/download-ds4-flash-vision-karmic-kraken-v1-checkpoint.sh" >&2
  exit 1
fi
checkpoint_marker="$(<"$HF_CACHE_HOST/.download-complete")"
[ "$checkpoint_marker" = "$CHECKPOINT $MODEL_REVISION" ] || {
  echo "error: checkpoint marker is '$checkpoint_marker', expected '$CHECKPOINT $MODEL_REVISION'" >&2
  exit 1
}
snapshot_dir="$HF_CACHE_HOST/hub/models--${CHECKPOINT%%/*}--${CHECKPOINT##*/}/snapshots/$MODEL_REVISION"
[ -f "$snapshot_dir/config.json" ] || {
  echo "error: pinned snapshot is incomplete at $snapshot_dir" >&2
  exit 1
}
for record in \
  "config.json:6cd841bdd6702f5e2ac34671bc78047ed80817102465525ae2a41c502abbcd75" \
  "generation_config.json:5fccff80f55a4d455bbe516bdd552edf3e9623df95e99fbf2a3c3389fdf91af0" \
  "tokenizer_config.json:6ac8c8dc065ed118161d02dd532749ae3f52c243deac27872134fae2f50d8547" \
  "model.safetensors.index.json:507977e3d3818865264e68c0fdab139aa7f3929d0d0cf693dacc47428da56395"; do
  metadata_file="${record%%:*}"
  metadata_digest="${record#*:}"
  actual_digest="$(sha256sum "$snapshot_dir/$metadata_file" | cut -d' ' -f1)"
  [ "$actual_digest" = "$metadata_digest" ] || {
    echo "error: $metadata_file sha256 is $actual_digest, Karmic Kraken evidence pins $metadata_digest" >&2
    exit 1
  }
done
printf 'PASS: checkpoint marker + Karmic Kraken metadata hashes\n'

# Preflight is static-only by design: the transactional switcher runs it while
# the previous profile is still serving, so no GPU/port gates belong here.
if [ "$MODE" = --preflight ]; then
  driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1)"
  echo "DS4 Vision Karmic Kraken v1 preflight: PASS (image pin, launch plan, checkpoint cache + metadata hashes)"
  echo "Host NVIDIA driver: ${driver_version:-<unknown>} (upstream tests 615.65.02; a CUDA-runtime probe at launch proves compatibility)"
  echo "Context is pinned to $MAX_MODEL_LEN (the benchmark arm); the Karmic Kraken Max-Q host measured 1,291,085 logical KV tokens. The switcher records the exact boot value."
  exit 0
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

inference_remove_container_if_present "$NAME"
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  echo "error: host port 8000 is already listening; use the transactional switcher when ready to replace the active profile" >&2
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

if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_DS4_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/ds4-flash/karmic-kraken-v1.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF
# The checkpoint is public, but a saved local token removes any rate/gating
# surprise on the first download; it stays out of the environment otherwise.
if [ -r "$INFERENCE_OPERATOR_HOME/.cache/huggingface/token" ]; then
  printf 'HF_TOKEN=%s\n' "$(<"$INFERENCE_OPERATOR_HOME/.cache/huggingface/token")" >>"$ENVFILE"
fi

# CUDA runtime probe: one-shot, now that every GPU gate passed (GPUs idle,
# image pinned, ports free). The upstream benchmark ran driver 615.65.02 on a
# CUDA 13.4.1 image; this probe exercises the components vLLM's TP2 path
# actually links — cuBLAS + cuDNN on the first GPU, then a real deterministic
# two-GPU NCCL allreduce — so an older-but-compatible driver (CUDA minor
# version compatibility) is accepted and an incompatible one fails closed
# before the serving container starts.
cuda_runtime_probe() {
  local first_gpu="${GPU_ORDER%%,*}" probe_dir
  probe_dir="$(mktemp -d)"
  trap 'rm -rf "$probe_dir"' RETURN
  cat >"$probe_dir/nccl_probe.py" <<'PY'
import torch
import torch.distributed as dist


def worker(rank, world=2):
    torch.cuda.set_device(rank)
    dist.init_process_group("nccl", init_method="tcp://127.0.0.1:29555", rank=rank, world_size=world)
    x = torch.ones(8 * 1024 * 1024, device="cuda") * (rank + 1)
    dist.all_reduce(x)
    expected = float(world * (world + 1) / 2)
    assert torch.allclose(x, torch.full_like(x, expected)), "allreduce did not exchange data"
    dist.destroy_process_group()


if __name__ == "__main__":
    torch.multiprocessing.spawn(worker, nprocs=2, join=True)
PY
  if ! docker run --rm --gpus "device=$first_gpu" --entrypoint /opt/venv/bin/python \
    "$IMAGE_CONFIG" -c '
import torch
import torch.nn.functional as F
x = torch.randn(1024, 1024, device="cuda")
assert torch.isfinite(x @ x).all()
w = torch.randn(16, 8, 3, 3, device="cuda")
img = torch.randn(1, 8, 64, 64, device="cuda")
assert torch.isfinite(F.conv2d(img, w)).all()
' >/dev/null 2>&1; then
    echo "error: CUDA runtime probe failed (cuBLAS/cuDNN) on the pinned image; the host driver cannot run this CUDA 13.4 image" >&2
    return 1
  fi
  if ! docker run --rm --gpus all --ipc host \
    -e CUDA_VISIBLE_DEVICES="$GPU_ORDER" \
    -v "$probe_dir/nccl_probe.py:/probe.py:ro" \
    --entrypoint /opt/venv/bin/python \
    "$IMAGE_CONFIG" /probe.py >/dev/null 2>&1; then
    echo "error: NCCL allreduce probe failed on the pinned image; the host driver or P2P path cannot run this CUDA 13.4 image" >&2
    return 1
  fi
  echo "CUDA RUNTIME PROBE: PASS (cuBLAS + cuDNN on device $first_gpu, NCCL allreduce across $GPU_ORDER)"
}
cuda_runtime_probe

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

gen_native_args=()
if [ -n "$GEN_OVERRIDES" ]; then
  gen_native_args=(--override-generation-config "$GEN_OVERRIDES")
fi

docker run -d --init \
  --restart no \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile="$NAME" \
  --label ai.peterstorm.inference.image-config="$IMAGE_CONFIG" \
  --label ai.peterstorm.inference.checkpoint="$CHECKPOINT@$MODEL_REVISION" \
  --label ai.peterstorm.inference.checkpoint-cache=host-offline-pinned \
  --label ai.peterstorm.inference.profile-env="$PROFILE" \
  --label ai.peterstorm.inference.hardware-profile=rtx-pro-6000-pcie \
  --label ai.peterstorm.inference.speculation=dspark-k3 \
  --label ai.peterstorm.inference.parallelism=tp2-dcp1 \
  --label ai.peterstorm.inference.kv-cache=fp8-block-256 \
  --label ai.peterstorm.inference.context-cap="$MAX_MODEL_LEN" \
  --label ai.peterstorm.inference.slots="$MAX_NUM_SEQS" \
  --label ai.peterstorm.inference.prefill-budget="$MAX_NUM_BATCHED_TOKENS" \
  --label ai.peterstorm.inference.gpu-memory-utilization="$GPU_MEMORY_UTILIZATION" \
  --label ai.peterstorm.inference.cache-mode="$CACHE_MODE" \
  --label ai.peterstorm.inference.sampling=benchmark-temperature-1-top-p-1 \
  --label ai.peterstorm.inference.source-benchmark=rtx6kpro/benchmarks/karmic-kraken-serving.md \
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
  -e PROFILE="$PROFILE" \
  -e HARDWARE_PROFILE=rtx-pro-6000-pcie \
  -e TP=2 \
  -e DCP=1 \
  -e PORT=8000 \
  -e SERVED_MODEL_NAME="$SERVED_MODEL" \
  -e MODEL_REVISION="$MODEL_REVISION" \
  -e HF_HUB_OFFLINE=1 \
  -e MAX_MODEL_LEN="$MAX_MODEL_LEN" \
  -e MAX_NUM_SEQS="$MAX_NUM_SEQS" \
  -e MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS" \
  -e GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION" \
  -e OMP_NUM_THREADS=2 \
  -e VLLM_USE_BREAKABLE_CUDAGRAPH=0 \
  -e NCCL_SOCKET_IFNAME=lo \
  -e GLOO_SOCKET_IFNAME=lo \
  "${cache_env[@]}" \
  "$IMAGE_CONFIG" \
  "${gen_native_args[@]+"${gen_native_args[@]}"}" \
  >/dev/null

printf "Started DS4 Vision Karmic Kraken v1 profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' "Serves $CHECKPOINT@$MODEL_REVISION offline from the host hub cache; the engine cannot fetch anything else."
printf '%s\n' "Served model id: $SERVED_MODEL (Pi/catalog-compatible). Context cap $MAX_MODEL_LEN, $MAX_NUM_SEQS slots, DSpark K3."
printf '%s\n' "Sampling override: ${GEN_OVERRIDES:-<profile default: temperature 1, top-p 0.95>}."
printf '%s\n' 'The Karmic Kraken Max-Q host measured 1,291,085 logical KV tokens at 325 W; this workstation pins 400 W (declarative). The switcher records the exact boot value.'
