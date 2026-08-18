#!/usr/bin/env bash
# Switch the workstation to the concurrent BF16 Qwen + Muse Glimmer profile.
#
# Physical GPU1: Qwen3.8-27B BF16, vLLM TP1, :8000.
# Physical GPU0: Muse Glimmer 30B BF16 + DFlash, SGLang TP1, :8001.
#
# The script preflights both checkpoints and the 350 W safety cap before stopping
# the mutually exclusive TP2 containers. It then waits until both authenticated
# endpoints are healthy. On a failed transition, both new containers are removed
# instead of leaving a half-installed dual profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"

QWEN_RUN="$SCRIPT_DIR/../qwen38/run-qwen38-27b-bf16.sh"
MUSE_RUN="$SCRIPT_DIR/../muse/run-muse-glimmer-30b-bf16-dflash.sh"
QWEN_NAME="qwen38-27b-bf16"
MUSE_NAME="muse-glimmer-30b-bf16-dflash"
QWEN_PORT=8000
MUSE_PORT=8001
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-1800}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-350}"
MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"
QWEN_MAX_NUM_SEQS="${QWEN_MAX_NUM_SEQS:-4}"
QWEN_GPU_MEMORY_UTILIZATION="${QWEN_GPU_MEMORY_UTILIZATION:-0.90}"
MUSE_MAX_RUNNING_REQUESTS="${MUSE_MAX_RUNNING_REQUESTS:-4}"
MUSE_MEM_FRACTION_STATIC="${MUSE_MEM_FRACTION_STATIC:-0.85}"

for numeric in HEALTH_TIMEOUT_SECONDS MAX_GPU_POWER_LIMIT MAX_EXISTING_GPU_MEMORY_MIB QWEN_MAX_NUM_SEQS MUSE_MAX_RUNNING_REQUESTS; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer (got: $value)" >&2
    exit 2
  fi
done
for launcher in "$QWEN_RUN" "$MUSE_RUN"; do
  if [ ! -x "$launcher" ]; then
    echo "error: launcher is missing or not executable: $launcher" >&2
    exit 1
  fi
done
if [ ! -e /models/Qwen3.8-27B/config.json ]; then
  echo "error: Qwen checkpoint is missing; run scripts/inference/qwen38/download-qwen38-27b.sh" >&2
  exit 1
fi
MUSE_CHECKPOINTS=(
  "/models/Muse-Glimmer-30B|meta-models/Muse-Glimmer-30B@a4e59da52a7bc87ae7251dd5545c0dd437c44b68"
  "/models/Muse-Glimmer-30B-assistant|meta-models/Muse-Glimmer-30B-assistant@e8192f3a8f617f74be2ce220360c89ef4789f39f"
)
for checkpoint in "${MUSE_CHECKPOINTS[@]}"; do
  IFS='|' read -r muse_path expected_marker <<<"$checkpoint"
  if [ ! -e "$muse_path/config.json" ] ||
     [ ! -e "$muse_path/.download-complete" ] ||
     ! grep -Fxq "$expected_marker" "$muse_path/.download-complete"; then
    echo "error: Muse checkpoint is incomplete or not pinned at $muse_path" >&2
    echo "       run scripts/inference/muse/download-muse-glimmer-30b.sh and wait for DOWNLOAD_COMPLETE" >&2
    exit 1
  fi
done
if systemctl is-active --quiet display-manager; then
  echo "error: display-manager is active and retains memory on physical GPU0" >&2
  echo "       run: sudo systemctl stop display-manager" >&2
  exit 3
fi

mapfile -t gpu_caps < <(nvidia-smi --query-gpu=index,power.limit --format=csv,noheader,nounits 2>/dev/null)
if [ "${#gpu_caps[@]}" -ne 2 ]; then
  echo "error: expected two queryable GPUs; found ${#gpu_caps[@]}" >&2
  exit 3
fi
for record in "${gpu_caps[@]}"; do
  IFS=',' read -r gpu_index gpu_cap <<<"$record"
  gpu_index="${gpu_index//[[:space:]]/}"
  gpu_cap="${gpu_cap//[[:space:]]/}"
  if ! [[ "$gpu_index" =~ ^[01]$ && "$gpu_cap" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "error: could not parse GPU power-cap record: $record" >&2
    exit 3
  fi
  if awk -v cap="$gpu_cap" -v maximum="$MAX_GPU_POWER_LIMIT" 'BEGIN { exit !(cap > maximum) }'; then
    echo "error: GPU $gpu_index cap is ${gpu_cap}W; profile maximum is ${MAX_GPU_POWER_LIMIT}W" >&2
    exit 3
  fi
done
echo "Preflight passed: both GPUs are queryable and capped at <= ${MAX_GPU_POWER_LIMIT}W."

# Stop every repository-owned inference profile that can conflict for a port or
# GPU. Keep stopped containers until their own launcher archives/replaces them;
# deleting here would destroy the Qwen crash evidence. Unrelated containers stay untouched.
CONFLICTING_CONTAINERS=(
  ds4-0731-r31
  ds4-0731-r33
  qwen38-27b-bf16
  qwen38-27b-bf16-dspark-sglang
  qwen38-27b-bf16-dspark-vllm
  muse-glimmer-30b-bf16-dflash
)
for container in "${CONFLICTING_CONTAINERS[@]}"; do
  docker stop "$container" >/dev/null 2>&1 || true
done

mapfile -t gpu_memory < <(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null)
if [ "${#gpu_memory[@]}" -ne 2 ]; then
  echo "error: both GPUs must remain queryable after stopping the previous profile" >&2
  exit 3
fi
for record in "${gpu_memory[@]}"; do
  IFS=',' read -r gpu_index memory_used <<<"$record"
  gpu_index="${gpu_index//[[:space:]]/}"
  memory_used="${memory_used//[[:space:]]/}"
  if ! [[ "$gpu_index" =~ ^[01]$ && "$memory_used" =~ ^[0-9]+$ ]]; then
    echo "error: could not parse post-stop GPU memory record: $record" >&2
    exit 3
  fi
  if ((memory_used > MAX_EXISTING_GPU_MEMORY_MIB)); then
    echo "error: GPU $gpu_index still uses ${memory_used} MiB after the profile stop" >&2
    echo "another process owns the card; refusing to launch over it" >&2
    exit 3
  fi
done

cleanup_failed_transition() {
  status=$?
  trap - ERR INT TERM
  echo "Dual-profile transition failed; removing both new containers." >&2
  docker rm -f "$QWEN_NAME" "$MUSE_NAME" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup_failed_transition ERR INT TERM

TP_SIZE=1 \
GPU_DEVICES=1 \
PORT="$QWEN_PORT" \
MAX_NUM_SEQS="$QWEN_MAX_NUM_SEQS" \
GPU_MEMORY_UTILIZATION="$QWEN_GPU_MEMORY_UTILIZATION" \
SPEC_MTP=0 \
  bash "$QWEN_RUN"

GPU_DEVICE=0 \
PORT="$MUSE_PORT" \
MAX_RUNNING_REQUESTS="$MUSE_MAX_RUNNING_REQUESTS" \
MEM_FRACTION_STATIC="$MUSE_MEM_FRACTION_STATIC" \
MAX_GPU_POWER_LIMIT="$MAX_GPU_POWER_LIMIT" \
MAX_EXISTING_GPU_MEMORY_MIB="$MAX_EXISTING_GPU_MEMORY_MIB" \
  bash "$MUSE_RUN"

inference_resolve_client_keyfile || {
  echo "error: no readable inference API key exists after launch" >&2
  false
}
api_key="$(<"$INFERENCE_CLIENT_KEYFILE")"
inference_validate_api_key "$api_key"

endpoint_is_healthy() {
  local port="$1"
  printf 'header = "Authorization: Bearer %s"\nurl = "http://127.0.0.1:%s/health"\n' \
    "$api_key" "$port" |
    curl --silent --show-error --fail --output /dev/null --config -
}

started_at="$(date +%s)"
while true; do
  for container in "$QWEN_NAME" "$MUSE_NAME"; do
    running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)"
    if [ "$running" != true ]; then
      echo "error: $container exited during startup" >&2
      docker logs --tail 100 "$container" >&2 2>/dev/null || true
      false
    fi
  done

  qwen_ready=0
  muse_ready=0
  endpoint_is_healthy "$QWEN_PORT" && qwen_ready=1 || true
  endpoint_is_healthy "$MUSE_PORT" && muse_ready=1 || true
  if [ "$qwen_ready" -eq 1 ] && [ "$muse_ready" -eq 1 ]; then
    break
  fi

  now="$(date +%s)"
  if ((now - started_at >= HEALTH_TIMEOUT_SECONDS)); then
    echo "error: both endpoints did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s" >&2
    false
  fi
  sleep 5
done

trap - ERR INT TERM
echo "Dual inference profile is healthy:"
echo "  Qwen: http://127.0.0.1:$QWEN_PORT/v1  (physical GPU1, BF16 TP1)"
echo "  Muse: http://127.0.0.1:$MUSE_PORT/v1  (physical GPU0, BF16 + DFlash TP1)"
echo "Use Pi models desktop-vllm/qwen3.8-27b and desktop-muse/muse-glimmer-30b."
