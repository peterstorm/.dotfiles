#!/usr/bin/env bash
# Activate the creative workstation profile:
#   physical GPU0: Muse Glimmer prompt author on :8001
#   physical GPU1: Nix-managed ComfyUI on loopback :8188
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../inference/shared/inference-api-key.sh"

MUSE_LAUNCHER="$SCRIPT_DIR/../inference/muse/run-muse-glimmer-30b-bf16-dflash.sh"
MUSE_NAME="muse-glimmer-30b-bf16-dflash"
MUSE_URL="http://127.0.0.1:8001"
COMFY_URL="http://127.0.0.1:8188"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-1800}"

if ! [[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: HEALTH_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
if [ ! -x "$MUSE_LAUNCHER" ]; then
  echo "error: Muse launcher is missing: $MUSE_LAUNCHER" >&2
  exit 1
fi
if ! systemctl cat comfyui.service >/dev/null 2>&1; then
  echo "error: comfyui.service is not installed; apply the desktop NixOS configuration" >&2
  exit 1
fi
if ! systemctl show comfyui.service -p Environment --value | grep -q 'CUDA_VISIBLE_DEVICES=1'; then
  echo "error: comfyui.service is not pinned to physical GPU1" >&2
  exit 1
fi
if [ ! -e /models/Muse-Glimmer-30B/config.json ] ||
   [ ! -e /models/Muse-Glimmer-30B-assistant/config.json ]; then
  echo "error: Muse checkpoints are incomplete; run the Muse downloader first" >&2
  exit 1
fi

KNOWN_INFERENCE_CONTAINERS=(
  ds4-0731-r31
  ds4-0731-r33
  qwen38-27b-bf16
  qwen38-27b-bf16-dspark-vllm-v2
  qwen38-27b-bf16-dspark-sglang-v2
  qwen38-27b-bf16-dspark-vllm
  qwen38-27b-bf16-dspark-sglang
  qwen38-27b-bf16-dflash2-sglang
  qwen38-27b-bf16-dflash2-sglang-native
  qwen38-27b-bf16-dflash2-vllm
)

is_running() {
  docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

mapfile -t prior_running < <(
  for container in "${KNOWN_INFERENCE_CONTAINERS[@]}"; do
    is_running "$container" && printf '%s\n' "$container"
  done
)
muse_was_running=0
is_running "$MUSE_NAME" && muse_was_running=1
comfy_was_active=0
systemctl is-active --quiet comfyui.service && comfy_was_active=1

rollback() {
  local status=$?
  trap - ERR INT TERM
  echo "Creative-stack activation failed; restoring the previous GPU profile." >&2
  sudo systemctl stop comfyui.service >/dev/null 2>&1 || true
  if [ "$muse_was_running" -eq 0 ]; then
    docker stop -t 30 "$MUSE_NAME" >/dev/null 2>&1 || true
  fi
  for container in "${prior_running[@]}"; do
    docker start "$container" >/dev/null 2>&1 || true
  done
  if [ "$comfy_was_active" -eq 1 ]; then
    sudo systemctl start comfyui.service >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap rollback ERR INT TERM

for container in "${prior_running[@]}"; do
  docker stop -t 30 "$container" >/dev/null
  echo "Stopped conflicting inference container: $container"
done
if [ "$comfy_was_active" -eq 1 ]; then
  sudo systemctl stop comfyui.service
fi

mapfile -t gpu_memory < <(
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits
)
if [ "${#gpu_memory[@]}" -ne 2 ]; then
  echo "error: expected two queryable GPUs" >&2
  false
fi
for record in "${gpu_memory[@]}"; do
  IFS=',' read -r index used <<<"$record"
  index="${index//[[:space:]]/}"
  used="${used//[[:space:]]/}"
  if ! [[ "$index" =~ ^[01]$ && "$used" =~ ^[0-9]+$ ]]; then
    echo "error: invalid GPU memory record: $record" >&2
    false
  fi
  if ((used > 2048)) && ! { [ "$index" -eq 0 ] && [ "$muse_was_running" -eq 1 ]; }; then
    echo "error: physical GPU $index still uses $used MiB after stopping conflicts" >&2
    false
  fi
done

sudo systemctl start comfyui.service

if [ "$muse_was_running" -eq 0 ]; then
  GPU_DEVICE=0 PORT=8001 bash "$MUSE_LAUNCHER"
else
  echo "$MUSE_NAME is already running on physical GPU0; preserving it."
fi

inference_resolve_client_keyfile || {
  echo "error: no readable Muse/inference API key exists" >&2
  false
}
api_key="$(<"$INFERENCE_CLIENT_KEYFILE")"
inference_validate_api_key "$api_key"

muse_healthy() {
  printf 'silent\nshow-error\nfail\noutput = "/dev/null"\nurl = "%s/health"\nheader = "Authorization: Bearer %s"\n' \
    "$MUSE_URL" "$api_key" | curl --config -
}

started_at="$(date +%s)"
while ! curl -fsS -m 3 "$COMFY_URL/system_stats" >/dev/null 2>&1 || ! muse_healthy; do
  if ! is_running "$MUSE_NAME"; then
    echo "error: $MUSE_NAME exited during startup" >&2
    docker logs --tail 100 "$MUSE_NAME" >&2 2>/dev/null || true
    false
  fi
  if ! systemctl is-active --quiet comfyui.service; then
    echo "error: comfyui.service exited during startup" >&2
    journalctl -u comfyui.service -n 100 --no-pager >&2 || true
    false
  fi
  if (( $(date +%s) - started_at >= HEALTH_TIMEOUT_SECONDS )); then
    echo "error: creative stack did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s" >&2
    false
  fi
  sleep 5
done

trap - ERR INT TERM
cat <<EOF
CREATIVE_STACK_READY
Muse prompt author: $MUSE_URL/v1 (physical GPU0)
ComfyUI:           $COMFY_URL (physical GPU1, loopback only)
From another machine:
  ssh -N -L 8188:127.0.0.1:8188 desktop
Then open http://127.0.0.1:8188 in your local browser.
EOF
