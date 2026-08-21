#!/usr/bin/env bash
# Switch the workstation to the concurrent BF16 Qwen + Muse Glimmer profile.
#
# Physical GPU1: Qwen3.8-27B BF16, vLLM TP1, :8000.
# Physical GPU0: Muse Glimmer 30B BF16 + DFlash, SGLang TP1, :8001.
#
# The script preflights both checkpoints and the 450 W safety cap before stopping
# the mutually exclusive TP2 containers. It then waits until both authenticated
# endpoints are healthy. On a failed transition, both new containers are removed
# instead of leaving a half-installed dual profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$SCRIPT_DIR/../muse/muse-glimmer-variant.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
muse_resolve_variant "${MUSE_VARIANT:-standard}"

QWEN_RUN="${QWEN_RUN:-$SCRIPT_DIR/../qwen38/run-qwen38-27b-bf16.sh}"
MUSE_RUN="${MUSE_RUN:-$SCRIPT_DIR/../muse/run-muse-glimmer-30b-bf16-dflash.sh}"
QWEN_MODEL_ROOT="${QWEN_MODEL_ROOT:-/models/Qwen3.8-27B}"
QWEN_NAME="qwen38-27b-bf16"
MUSE_NAME="$MUSE_CONTAINER_NAME"
QWEN_PORT=8000
MUSE_PORT=8001
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-1800}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
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
if [ ! -e "$QWEN_MODEL_ROOT/config.json" ]; then
  echo "error: Qwen checkpoint is missing; run scripts/inference/qwen38/download-qwen38-27b.sh" >&2
  exit 1
fi
download_hint="run MUSE_VARIANT=$MUSE_VARIANT scripts/inference/muse/download-muse-glimmer-30b.sh and wait for DOWNLOAD_COMPLETE"
inference_require_pinned_checkpoint \
  "$MUSE_TARGET_HOST" "$MUSE_TARGET_REPO@$MUSE_TARGET_REV" "$MUSE_TARGET_MANIFEST" "$download_hint"
inference_require_pinned_checkpoint \
  "$MUSE_DRAFT_HOST" "$MUSE_DRAFT_REPO@$MUSE_DRAFT_REV" "$MUSE_DRAFT_MANIFEST" "$download_hint"

display_state_status=0
display_state="$(systemctl is-active display-manager 2>&1)" || display_state_status=$?
case "$display_state" in
  inactive) ;;
  active)
    echo "error: display-manager is active and retains memory on physical GPU0" >&2
    echo "       run: sudo systemctl stop display-manager" >&2
    exit 3
    ;;
  *)
    echo "error: could not prove display-manager is inactive (status $display_state_status): $display_state" >&2
    exit 3
    ;;
esac

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
docker info >/dev/null
mapfile -t CONFLICTING_CONTAINERS < <(inference_profile_containers_except "")
for container in "${CONFLICTING_CONTAINERS[@]}"; do
  inference_stop_container_if_present "$container"
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
  local status=$? cleanup_failed=0 container
  trap - ERR INT TERM
  echo "Dual-profile transition failed; removing both new containers." >&2
  for container in "$QWEN_NAME" "$MUSE_NAME"; do
    inference_remove_container_if_present "$container" || cleanup_failed=1
  done
  if [ "$cleanup_failed" -ne 0 ]; then
    echo "error: dual-profile cleanup was incomplete" >&2
    exit 70
  fi
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

MUSE_VARIANT="$MUSE_VARIANT" \
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
    running_status=0
    inference_container_running "$container" || running_status=$?
    if [ "$running_status" -ne 0 ]; then
      if [ "$running_status" -eq 1 ]; then
        echo "error: $container exited during startup" >&2
        docker logs --tail 100 "$container" >&2 2>/dev/null || true
      fi
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
echo "  Muse: http://127.0.0.1:$MUSE_PORT/v1  (physical GPU0, $MUSE_VARIANT BF16 + DFlash TP1)"
echo "Use Pi models desktop-vllm/qwen3.8-27b and desktop-muse/muse-glimmer-30b."
