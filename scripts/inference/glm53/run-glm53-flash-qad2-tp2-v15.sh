#!/usr/bin/env bash
# GLM-5.3 v15: the upstream Karmic Kraken beta build 20261015.2 launched
# through lil-serve with the glm53-tp2 preset on the qad2 checkpoint
# (local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD @ 0a041763…):
# TP2/DCP2, MTP3, eight slots, 4096-token prefill budget, 7296 MiB/GPU fixed
# FP8 KV (~1.84M KV tokens), memory-resolved ~1M context, vision, A4 expert
# prefill, KDA MXFP8 prefill activations, BF16 MTP draft head, glm47 tools.
#
# v15 follows the "GLM-5.3-Flash vLLM Recipe" (see the runbook) with the
# recipe's two deliberate changes vs the lab compose: CACHE_MODE=vram (no
# host-RAM KV tier) and server-default reasoning effort high instead of the
# preset's max (clients still override per request through
# chat_template_kwargs.reasoning_effort). The checkpoint is pre-downloaded by
# download-glm53-flash-qad2-tp2-v15-checkpoint.sh and served offline. What
# the repository owns:
#   - the exact image id (IMAGE_CONFIG, pulled by digest) and the exact
#     served model id (SERVED_MODEL_NAME overrides the preset's name);
#   - one launcher argv (LIL_SERVE_ARGS), used both for the CPU-only
#     --print-config proof and the real launch, so the proof cannot drift
#     from what serves;
#   - the workstation gates: exactly two RTX PRO 6000 Blackwell cards at the
#     declarative gpuPowerLimitWatts pin (machines/desktop/default.nix),
#     memory idle, comfyui stopped, port 8000 free;
#   - the transactional shape: --restart no here, unless-stopped only after
#     the switcher accepts the boot;
#   - no overrides of the preset's memory contract. The recipe measured that
#     pinning a 524288-token max model len regroups the hybrid KV cache and shrinks
#     the pool from 1,844,162 to 1,561,213 tokens on the same memory; keep the
#     preset's 1M and cap context in the client (pi/models.json).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

# Pinned by pull-glm53-flash-qad2-tp2-v15-image.sh on the serving host.
IMAGE_CONFIG="sha256:02c46866e4358592f43083980b35f73fbd08c723813b92f8205ab6446bc2b45d"
PULL_DIGEST="sha256:a7dc6c5f23310c0949e72fc1977fdcdaa5d8a4e1a9e7ee8f2482e6163b296178"
PRESET="glm53-tp2"
CHECKPOINT="local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD"
# Pinned by download-glm53-flash-qad2-tp2-v15-checkpoint.sh on the serving
# host; the offline gate refuses to serve anything else, and the launch-plan
# proof requires the preset to resolve this same revision.
MODEL_REVISION="0a0417631b4065d16e9639f327f44a0a4237a537"
NAME="glm53-flash-qad2-tp2-v15"
SERVED_MODEL="glm-5.3-flash-qad2-tp2-v15"
CHAT_TEMPLATE_KWARGS='{"reasoning_effort":"high","clear_thinking":false}'
HF_CACHE_HOST="${HF_CACHE_HOST:-/models/hf-cache/glm53-flash-qad2-tp2-v15}"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-qad2-tp2-v15}"
GPU_ORDER="${GPU_ORDER:-0,1}"
LIL_SERVE_ARGS=(--profile glm53-flash --hardware rtx-pro-6000-pcie --preset "$PRESET")
LIL_SERVE_NATIVE_ARGS=(-- --cache-mode vram)
MODE="${1:---launch}"

case "$MODE" in
  --launch | --preflight) ;;
  *) echo "usage: ${0##*/} [--launch|--preflight]" >&2; exit 2 ;;
esac
case "$GPU_ORDER" in
  0,1 | 1,0) ;;
  *) echo "error: GPU_ORDER must contain both physical GPUs exactly once: 0,1 or 1,0" >&2; exit 2 ;;
esac
# v15 is GPU-only by design (the recipe's CACHE_MODE=vram); the LMCache tier
# of v14 is not part of this profile.
if [ -n "${CACHE_MODE:-}" ] && [ "$CACHE_MODE" != vram ]; then
  echo "error: v15 serves CACHE_MODE=vram only (no host-RAM KV tier); unset CACHE_MODE" >&2
  exit 2
fi
# The old overlay switch set must not be carried into the upstream image.
for switch in VLLM_B12X_FP8_KV VLLM_B12X_GLM_NOPE_NVFP4 VLLM_DCP_GLOBAL_TOPK \
  VLLM_USE_B12X_DCP_A2A TRELLIS ROUTE128 PCIE_ALLREDUCE GLM_NOPE_FP8 \
  VLLM_MAMBA_STATE_PROTECT VLLM_MAMBA_ALIGN_CAP_LEGACY; do
  if [ -n "${!switch:-}" ]; then
    echo "error: $switch belongs to the retired EXL3 K4 patch series; unset it for v15" >&2
    exit 2
  fi
done
[[ "$IMAGE_CONFIG" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "error: IMAGE_CONFIG must be the recorded image id (sha256:<64 hex>)" >&2
  exit 2
}

if ! actual_image_id="$(docker image inspect "$IMAGE_CONFIG" --format '{{.Id}}' 2>/dev/null)"; then
  echo "error: pinned GLM v15 image is absent; run scripts/inference/glm53/pull-glm53-flash-qad2-tp2-v15-image.sh" >&2
  exit 1
fi
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || {
  echo "error: local GLM v15 image id is $actual_image_id, expected $IMAGE_CONFIG" >&2
  exit 1
}
# The image must be the one the recipe's digest names, not a re-tag.
if ! docker image inspect "$IMAGE_CONFIG" --format '{{json .RepoDigests}}' \
  | jq -e --arg digest "$PULL_DIGEST" 'any(.[]; endswith("@" + $digest))' >/dev/null 2>&1; then
  echo "error: $IMAGE_CONFIG is not the image published under $PULL_DIGEST; re-pin with the pull script" >&2
  exit 1
fi

# CPU-only launch-plan proof with the exact launch argv and environment.
plan_proof="$(docker run --rm --runtime runc --network none \
  -e PRESET="$PRESET" -e CACHE_MODE=vram \
  -e SERVED_MODEL_NAME="$SERVED_MODEL" \
  -e DEFAULT_CHAT_TEMPLATE_KWARGS="$CHAT_TEMPLATE_KWARGS" \
  --entrypoint /usr/local/bin/lil-serve "$IMAGE_CONFIG" \
  "${LIL_SERVE_ARGS[@]}" --print-config "${LIL_SERVE_NATIVE_ARGS[@]}" 2>/dev/null)" || {
  echo "error: --print-config failed for the pinned v15 image" >&2
  exit 1
}
if ! jq -e --arg model "$SERVED_MODEL" --arg revision "$MODEL_REVISION" --arg checkpoint "$CHECKPOINT" '
  .profile == "glm53-flash"
  and .hardware == "rtx-pro-6000-pcie"
  and .settings.model.value == $checkpoint
  and .settings.revision.value == $revision
  and .settings["served-model-name"].value == $model
  and .settings["tensor-parallel-size"].value == 2
  and .settings["decode-context-parallel-size"].value == 2
  and .settings["kv-cache-memory-bytes"].value == 7650410496
  and .settings["max-num-seqs"].value == 8
  and .settings["max-model-len"].value == -1
  and .settings["cache-mode"].value == "vram"
  and .settings["default-chat-template-kwargs"].value.reasoning_effort == "high"
' <<<"$plan_proof" >/dev/null 2>&1; then
  echo "error: pinned image no longer resolves the documented v15 launch plan" >&2
  exit 1
fi

# Offline checkpoint gate: the marker is written by the download script after
# snapshot_download(local_files_only=True) succeeds. Static by design: both
# preflight and launch require it.
if [ ! -r "$HF_CACHE_HOST/.download-complete" ]; then
  echo "error: checkpoint cache is absent at $HF_CACHE_HOST; run scripts/inference/glm53/download-glm53-flash-qad2-tp2-v15-checkpoint.sh" >&2
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

# Preflight is static-only by design: the transactional switcher runs it while
# the previous profile is still serving, so no GPU/port gates belong here.
if [ "$MODE" = --preflight ]; then
  driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1)"
  echo "GLM-5.3 v15 qad2 glm53-tp2 preflight: PASS (image pin, launch plan, checkpoint cache)"
  echo "Host NVIDIA driver: ${driver_version:-<unknown>} (image built against 615.65.02 / CUDA 13.4; a CUDA-runtime probe at launch proves compatibility)"
  echo "Capacity is intentionally not predicted: the preset resolves max-model-len from memory (recipe: 1,048,576 context, 1,844,162 KV tokens). The switcher records the exact boot value."
  exit 0
fi

# The expected wattage is the declarative pin (gpuPowerLimitWatts in
# machines/desktop/default.nix), not a hardcoded constant. The dotfiles root
# is walked up from this script, anchored on the config itself; missing or
# unpinned config fails closed.
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
  echo "error: host port 8000 is already listening; use the v15 switcher when ready to replace the active profile" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_GLM_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/flash-qad2-tp2-v15.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

if ! mkdir -p "$CACHE_HOST" 2>/dev/null || [ ! -w "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

# CUDA runtime probe: one-shot, now that every GPU gate passed. The image is
# built against driver 615.65.02 / CUDA 13.4; this probe exercises the
# components vLLM's TP2/DCP2 path links — cuBLAS + cuDNN on the first GPU,
# then a real two-GPU NCCL allreduce — so an older-but-compatible driver
# (CUDA minor version compatibility) is accepted and an incompatible one fails
# closed before the serving container starts.
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

docker run -d --init \
  --restart no \
  --stop-timeout 180 \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=glm53-flash-qad2-tp2-v15 \
  --label ai.peterstorm.inference.image-config="$IMAGE_CONFIG" \
  --label ai.peterstorm.inference.image-digest="$PULL_DIGEST" \
  --label ai.peterstorm.inference.checkpoint="$CHECKPOINT@$MODEL_REVISION" \
  --label ai.peterstorm.inference.checkpoint-cache=host-offline-pinned \
  --label ai.peterstorm.inference.preset="$PRESET" \
  --label ai.peterstorm.inference.hardware-profile=rtx-pro-6000-pcie \
  --label ai.peterstorm.inference.speculation=mtp3 \
  --label ai.peterstorm.inference.parallelism=tp2-dcp2 \
  --label ai.peterstorm.inference.kv-cache=fp8-7296mib-per-gpu-fixed \
  --label ai.peterstorm.inference.default-effort=high \
  --label ai.peterstorm.inference.cache-mode=vram \
  --gpus "\"device=$GPU_ORDER\"" \
  --network host \
  --ipc host \
  --shm-size 32g \
  --ulimit memlock=-1 \
  --ulimit stack=67108864:67108864 \
  --security-opt seccomp=unconfined \
  --env-file "$ENVFILE" \
  -v "$HF_CACHE_HOST:/root/.cache/huggingface:ro" \
  -v "$CACHE_HOST:/cache" \
  -e PRESET="$PRESET" \
  -e CACHE_MODE=vram \
  -e HOST=0.0.0.0 \
  -e PORT=8000 \
  -e SERVED_MODEL_NAME="$SERVED_MODEL" \
  -e DEFAULT_CHAT_TEMPLATE_KWARGS="$CHAT_TEMPLATE_KWARGS" \
  -e HF_HUB_OFFLINE=1 \
  --entrypoint /usr/local/bin/lil-serve \
  "$IMAGE_CONFIG" \
  "${LIL_SERVE_ARGS[@]}" "${LIL_SERVE_NATIVE_ARGS[@]}"

printf "Started upstream karmic-kraken GLM qad2 TP2 profile '%s'. Follow: docker logs -f %s\n" "$NAME" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' 'v15 serves the pre-downloaded checkpoint offline: '"$CHECKPOINT@$MODEL_REVISION"' from the host hub cache (read-only); the engine cannot fetch anything else.'
printf '%s\n' 'Served model id: '"$SERVED_MODEL"'. First start ~8-9 min (kernel JIT), later ~4-5 min; the log should show GPU KV cache size: 1,844,162 tokens.'
printf '%s\n' 'Keep PRESET, KV, slots, prefill and the 1M context unchanged: pinning a shorter context shrinks the KV pool (recipe measurement).'
