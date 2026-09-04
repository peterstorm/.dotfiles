#!/usr/bin/env bash
# Activate the creative workstation profile:
#   physical GPU0: Blackfrost abliterated Qwen3.8-27B prompt author on :8000
#   physical GPU1: Nix-managed ComfyUI on loopback :8188
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../inference/shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../inference/shared/inference-profile-catalog.sh"

AUTHOR_LAUNCHER="${AUTHOR_LAUNCHER:-$SCRIPT_DIR/../inference/qwen38/run-qwen38-27b-blackfrost-abliterated-bf16-vllm.sh}"
AUTHOR_NAME="${AUTHOR_NAME:-qwen38-27b-blackfrost-abliterated-bf16-vllm}"
AUTHOR_MODEL_HOST="${AUTHOR_MODEL_HOST:-/models/Qwen3.8-27B-Blackfrost-Abliterated-BF16}"
AUTHOR_MODEL_PIN="Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16@9d85770e5eb602322b4bceef55beda357e0bd0ca"
AUTHOR_PROFILE="qwen38-27b-blackfrost-abliterated-bf16"
AUTHOR_PORT=8000
AUTHOR_URL="http://127.0.0.1:$AUTHOR_PORT"
COMFY_URL="http://127.0.0.1:8188"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-1800}"

if ! [[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: HEALTH_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
if [ ! -x "$AUTHOR_LAUNCHER" ]; then
  echo "error: prompt-author launcher is missing: $AUTHOR_LAUNCHER" >&2
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
# The downloader proved every artifact against the pinned manifest, so identity is
# what matters here. Fail early with the hint rather than deep inside the launcher.
if [ ! -f "$AUTHOR_MODEL_HOST/.download-complete" ] \
  || ! grep -Fxq "$AUTHOR_MODEL_PIN" "$AUTHOR_MODEL_HOST/.download-complete"; then
  echo "error: prompt-author checkpoint at $AUTHOR_MODEL_HOST lacks the pinned revision marker" >&2
  echo "       run scripts/inference/qwen38/download-qwen38-27b-blackfrost-abliterated-bf16.sh" >&2
  exit 1
fi

inference_resolve_client_keyfile || {
  echo "error: no readable inference API key exists" >&2
  exit 1
}
api_key="$(<"$INFERENCE_CLIENT_KEYFILE")"
inference_validate_api_key "$api_key"

author_healthy() {
  printf 'silent\nshow-error\nfail\noutput = "/dev/null"\nurl = "%s/health"\nheader = "Authorization: Bearer %s"\n' \
    "$AUTHOR_URL" "$api_key" | curl --config -
}

docker info >/dev/null
mapfile -t KNOWN_INFERENCE_CONTAINERS < <(inference_profile_containers_except "$AUTHOR_NAME")

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

author_was_running=0
running_status=0
inference_container_running "$AUTHOR_NAME" || running_status=$?
case "$running_status" in
  0)
    author_was_running=1
    inference_require_container_label "$AUTHOR_NAME" io.peterstorm.inference.profile "$AUTHOR_PROFILE"
    inference_require_container_label "$AUTHOR_NAME" io.peterstorm.inference.physical-gpu 0
    inference_require_container_label "$AUTHOR_NAME" io.peterstorm.inference.port "$AUTHOR_PORT"
    inference_require_container_label "$AUTHOR_NAME" io.peterstorm.inference.target-revision "$AUTHOR_MODEL_PIN"
    if ! author_healthy; then
      echo "error: existing $AUTHOR_NAME does not pass authenticated health" >&2
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
  if [ "$author_was_running" -eq 0 ]; then
    rollback_step "stop newly started prompt author" inference_stop_container_if_present "$AUTHOR_NAME" || rollback_failed=1
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
  if ((used > 2048)) && ! { [ "$index" -eq 0 ] && [ "$author_was_running" -eq 1 ]; }; then
    echo "error: physical GPU $index still uses $used MiB after stopping conflicts" >&2
    false
  fi
done

sudo systemctl start comfyui.service

if [ "$author_was_running" -eq 0 ]; then
  GPU_DEVICE=0 PORT="$AUTHOR_PORT" bash "$AUTHOR_LAUNCHER"
else
  echo "$AUTHOR_NAME is already running on physical GPU0; preserving it."
fi

started_at="$(date +%s)"
while ! curl -fsS -m 3 "$COMFY_URL/system_stats" >/dev/null 2>&1 || ! author_healthy; do
  running_status=0
  inference_container_running "$AUTHOR_NAME" || running_status=$?
  if [ "$running_status" -ne 0 ]; then
    if [ "$running_status" -eq 1 ]; then
      echo "error: $AUTHOR_NAME exited during startup" >&2
      docker logs --tail 100 "$AUTHOR_NAME" >&2 2>/dev/null || true
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
Prompt author: $AUTHOR_URL/v1 (physical GPU0, Blackfrost abliterated Qwen3.8-27B BF16)
ComfyUI:       $COMFY_URL (physical GPU1, loopback only)
From another machine:
  ssh -N -L 8188:127.0.0.1:8188 desktop
Then open http://127.0.0.1:8188 in your local browser.
EOF
