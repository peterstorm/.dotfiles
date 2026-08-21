#!/usr/bin/env bash
# Activate the creative workstation profile:
#   physical GPU0: Muse Glimmer prompt author on :8001
#   physical GPU1: Nix-managed ComfyUI on loopback :8188
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../inference/shared/inference-api-key.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$SCRIPT_DIR/../inference/muse/muse-glimmer-variant.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../inference/shared/inference-profile-catalog.sh"
muse_resolve_variant "${MUSE_VARIANT:-standard}"

MUSE_LAUNCHER="${MUSE_LAUNCHER:-$SCRIPT_DIR/../inference/muse/run-muse-glimmer-30b-bf16-dflash.sh}"
MUSE_NAME="$MUSE_CONTAINER_NAME"
MUSE_PORT=8001
MUSE_URL="http://127.0.0.1:$MUSE_PORT"
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
download_hint="run MUSE_VARIANT=$MUSE_VARIANT scripts/inference/muse/download-muse-glimmer-30b.sh and wait for DOWNLOAD_COMPLETE"
inference_require_pinned_checkpoint \
  "$MUSE_TARGET_HOST" "$MUSE_TARGET_REPO@$MUSE_TARGET_REV" "$MUSE_TARGET_MANIFEST" "$download_hint"
inference_require_pinned_checkpoint \
  "$MUSE_DRAFT_HOST" "$MUSE_DRAFT_REPO@$MUSE_DRAFT_REV" "$MUSE_DRAFT_MANIFEST" "$download_hint"

inference_resolve_client_keyfile || {
  echo "error: no readable Muse/inference API key exists" >&2
  exit 1
}
api_key="$(<"$INFERENCE_CLIENT_KEYFILE")"
inference_validate_api_key "$api_key"

muse_healthy() {
  printf 'silent\nshow-error\nfail\noutput = "/dev/null"\nurl = "%s/health"\nheader = "Authorization: Bearer %s"\n' \
    "$MUSE_URL" "$api_key" | curl --config -
}

docker info >/dev/null
mapfile -t KNOWN_INFERENCE_CONTAINERS < <(inference_profile_containers_except "$MUSE_NAME")

prior_running=()
for container in "${KNOWN_INFERENCE_CONTAINERS[@]}"; do
  running_status=0
  inference_container_running "$container" || running_status=$?
  case "$running_status" in
    0) prior_running+=("$container") ;;
    1) ;;
    *) exit "$running_status" ;;
  esac
done

muse_was_running=0
running_status=0
inference_container_running "$MUSE_NAME" || running_status=$?
case "$running_status" in
  0)
    muse_was_running=1
    inference_require_container_label "$MUSE_NAME" io.peterstorm.inference.profile muse-glimmer
    inference_require_container_label "$MUSE_NAME" io.peterstorm.inference.physical-gpu 0
    inference_require_container_label "$MUSE_NAME" io.peterstorm.inference.port "$MUSE_PORT"
    inference_require_container_label "$MUSE_NAME" io.peterstorm.inference.muse-variant "$MUSE_VARIANT"
    inference_require_container_label "$MUSE_NAME" io.peterstorm.inference.target-revision "$MUSE_TARGET_REV"
    inference_require_container_label "$MUSE_NAME" io.peterstorm.inference.draft-revision "$MUSE_DRAFT_REV"
    if ! muse_healthy; then
      echo "error: existing $MUSE_NAME does not pass authenticated health" >&2
      exit 1
    fi
    ;;
  1) ;;
  *) exit "$running_status" ;;
esac

comfy_was_active=0
comfy_state_status=0
comfy_state="$(systemctl is-active comfyui.service 2>&1)" || comfy_state_status=$?
case "$comfy_state" in
  active) comfy_was_active=1 ;;
  inactive|failed) ;;
  *)
    echo "error: could not determine comfyui.service state (status $comfy_state_status): $comfy_state" >&2
    exit 1
    ;;
esac

rollback_step() {
  local description="$1" output step_status
  shift
  if output="$("$@" 2>&1)"; then
    return 0
  else
    step_status=$?
  fi
  echo "rollback error: $description failed (status $step_status): $output" >&2
  return 1
}

rollback() {
  local status=$? rollback_failed=0 container
  trap - ERR INT TERM
  echo "Creative-stack activation failed; restoring the previous GPU profile." >&2
  rollback_step "stop ComfyUI" sudo systemctl stop comfyui.service || rollback_failed=1
  if [ "$muse_was_running" -eq 0 ]; then
    rollback_step "stop newly started Muse" inference_stop_container_if_present "$MUSE_NAME" || rollback_failed=1
  fi
  for container in "${prior_running[@]}"; do
    rollback_step "restart prior container $container" docker start "$container" || rollback_failed=1
  done
  if [ "$comfy_was_active" -eq 1 ]; then
    rollback_step "restart prior ComfyUI service" sudo systemctl start comfyui.service || rollback_failed=1
  fi
  if [ "$rollback_failed" -ne 0 ]; then
    echo "error: creative-stack rollback was incomplete" >&2
    exit 70
  fi
  exit "$status"
}
trap rollback ERR INT TERM

for container in "${prior_running[@]}"; do
  inference_stop_container_if_present "$container"
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
  MUSE_VARIANT="$MUSE_VARIANT" GPU_DEVICE=0 PORT=8001 bash "$MUSE_LAUNCHER"
else
  echo "$MUSE_NAME is already running on physical GPU0; preserving it."
fi

started_at="$(date +%s)"
while ! curl -fsS -m 3 "$COMFY_URL/system_stats" >/dev/null 2>&1 || ! muse_healthy; do
  running_status=0
  inference_container_running "$MUSE_NAME" || running_status=$?
  if [ "$running_status" -ne 0 ]; then
    if [ "$running_status" -eq 1 ]; then
      echo "error: $MUSE_NAME exited during startup" >&2
      docker logs --tail 100 "$MUSE_NAME" >&2 2>/dev/null || true
    fi
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
Muse prompt author: $MUSE_URL/v1 (physical GPU0, $MUSE_VARIANT BF16)
ComfyUI:           $COMFY_URL (physical GPU1, loopback only)
From another machine:
  ssh -N -L 8188:127.0.0.1:8188 desktop
Then open http://127.0.0.1:8188 in your local browser.
EOF
