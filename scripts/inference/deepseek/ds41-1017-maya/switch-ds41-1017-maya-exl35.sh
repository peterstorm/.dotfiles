#!/usr/bin/env bash
# Safely start/stop DeepSeek-V4.1-Flash-1017 on Project Maya (EXL3 3.5 bpw).
#
# start: preflight -> idle gate on the running profile (the vLLM profiles'
# /metrics) -> stop it -> launch Maya -> wait for /health plus an
# authenticated /v1/models naming exactly deepseek-v4.1-flash -> boot
# receipt -> restart=unless-stopped. Any failure after the previous profile
# stopped restarts it (normally GLM v15), so a bad boot leaves the GPUs back
# on the known-good profile, not idle.
# stop: stops Maya only. Back to v15 afterwards:
#   scripts/inference/glm53/switch-glm53-qad2-tp2-v15.sh start
# (with :8000 free, v15's switcher needs no idle gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../../shared/inference-profile-catalog.sh"

TARGET="ds41-1017-maya-exl35"
EXPECTED_MODEL="deepseek-v4.1-flash"
RUN="$SCRIPT_DIR/run-ds41-1017-maya-exl35.sh"
# A cold start pins ~85 GB of RAM, loads ~190 GB of experts into VRAM from the
# NVMe and warms the caches. Nothing compiles here: Maya's setup built the
# engine (see the runbook).
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-3600}"
BOOT_RECEIPT="${BOOT_RECEIPT:-$HOME/.local/state/ds41-maya/exl35-boot-receipt.txt}"
MODE="${1:-status}"

[[ "$STARTUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: STARTUP_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
}

running_profiles() {
  local container status
  for container in "${INFERENCE_PROFILE_CONTAINERS[@]}"; do
    status=0
    inference_container_running "$container" || status=$?
    case "$status" in
      0) printf '%s\n' "$container" ;;
      1) ;;
      *) return "$status" ;;
    esac
  done
}

authenticated_models() {
  local key="$1" escaped_key
  escaped_key="${key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"
  {
    printf 'url = "http://127.0.0.1:8000/v1/models"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_key"
    printf 'connect-timeout = 2\nmax-time = 10\nfail\n'
  } | curl --silent --show-error --config -
}

# The profiles this replaces are vLLM servers: no running or waiting request
# across three samples, or no cutover.
require_idle_endpoint() {
  local delay metrics active
  for delay in 0 3 3; do
    sleep "$delay"
    metrics="$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/metrics)" || {
      echo "error: active profile metrics are unavailable; refusing cutover" >&2
      return 1
    }
    active="$(awk '/vllm:num_requests_(running|waiting)\{/ {sum += $NF} END {print sum + 0}' <<<"$metrics")"
    if [ "$active" != 0 ]; then
      echo "error: $active request(s) are running or waiting; refusing cutover" >&2
      return 1
    fi
  done
  echo "IDLE GATE: no running or waiting requests across three samples"
}

wait_for_target() {
  local deadline status key models_json
  deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    status=0
    inference_container_running "$TARGET" || status=$?
    case "$status" in
      0) ;;
      1) echo "error: $TARGET exited during startup" >&2; return 1 ;;
      *) return "$status" ;;
    esac
    if curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/health 2>/dev/null \
      | jq -e '.status == "ok" and .unloaded == false' >/dev/null 2>&1; then
      inference_resolve_client_keyfile || {
        echo "error: no synchronized API key exists after launch" >&2
        return 1
      }
      key="$(<"$INFERENCE_CLIENT_KEYFILE")"
      models_json="$(authenticated_models "$key" 2>/dev/null)" || models_json=''
      if jq -e --arg expected "$EXPECTED_MODEL" '
        .data | type == "array" and length == 1 and .[0].id == $expected
      ' <<<"$models_json" >/dev/null 2>&1; then
        echo "HEALTHY + AUTHENTICATED + EXACT MODEL: $TARGET ($EXPECTED_MODEL)"
        return 0
      fi
    fi
    sleep 5
  done
  echo "error: $TARGET did not serve authenticated model $EXPECTED_MODEL within ${STARTUP_TIMEOUT_SECONDS}s" >&2
  return 1
}

# Where the experts landed is the number that explains the speed: keep the
# engine's placement and memory lines from this boot.
report_boot_receipt() {
  local logs image_id started_at commit receipt_dir receipt_tmp placement
  logs="$(docker logs "$TARGET" 2>&1)" || return 1
  image_id="$(docker inspect "$TARGET" --format '{{.Image}}')" || return 1
  started_at="$(docker inspect "$TARGET" --format '{{.State.StartedAt}}')" || return 1
  commit="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.maya-commit"}}')" || return 1
  placement="$(grep -iE 'expert|vram|ram tier|pinned|page cache|ssd|tensor parallel|dspark|context' <<<"$logs" | tail -n 30)"
  receipt_dir="$(dirname "$BOOT_RECEIPT")"
  install -d -m 700 "$receipt_dir"
  receipt_tmp="$(mktemp "$receipt_dir/.exl35-boot-receipt.XXXXXX")"
  {
    printf 'container=%s\nmodel=%s\nstarted_at=%s\nimage=%s\nmaya_commit=%s\n' \
      "$TARGET" "$EXPECTED_MODEL" "$started_at" "$image_id" "$commit"
    printf '%s\n' '--- placement / memory lines ---'
    printf '%s\n' "${placement:-<none captured>}"
  } >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -f "$receipt_tmp" "$BOOT_RECEIPT"
  echo "BOOT RECEIPT: $BOOT_RECEIPT (image=$image_id, maya=$commit)"
}

promote_restart_policy() {
  docker update --restart=unless-stopped "$TARGET" >/dev/null || {
    echo "error: could not promote $TARGET to restart=unless-stopped" >&2
    return 1
  }
  echo "PROMOTED: restart=unless-stopped"
}

restore_profiles() {
  local container failed=0
  for container in "$@"; do
    if ! docker start "$container" >/dev/null; then
      echo "error: rollback could not restart $container" >&2
      failed=1
    else
      echo "rollback restarted: $container"
    fi
  done
  return "$failed"
}

case "$MODE" in
  status)
    active_output="$(running_profiles)" || exit $?
    if [ -z "$active_output" ]; then
      echo "No repository-owned inference profile is running."
    else
      sed 's/^/running: /' <<<"$active_output"
    fi
    ;;
  stop)
    inference_stop_container_if_present "$TARGET"
    echo "Stopped $TARGET if it was present."
    ;;
  start)
    "$RUN" --preflight
    previous_output="$(running_profiles)" || exit $?
    previous=()
    [ -z "$previous_output" ] || mapfile -t previous <<<"$previous_output"
    for container in "${previous[@]}"; do
      if [ "$container" = "$TARGET" ]; then
        wait_for_target
        report_boot_receipt
        promote_restart_policy
        exit 0
      fi
    done
    if [ "${#previous[@]}" -gt 0 ]; then
      require_idle_endpoint
    fi
    stopped=()
    for container in "${previous[@]}"; do
      if ! inference_stop_container_if_present "$container"; then
        echo "error: profile quiesce failed; restoring already stopped profiles" >&2
        restore_profiles "${stopped[@]}" || true
        exit 1
      fi
      stopped+=("$container")
    done
    if ! "$RUN" --launch || ! wait_for_target; then
      echo "error: Maya launch or acceptance failed; restoring the previous profile set" >&2
      inference_quiesce_failed_container "$TARGET" || true
      restore_profiles "${stopped[@]}" || true
      exit 1
    fi
    report_boot_receipt
    promote_restart_policy
    ;;
  *)
    echo "usage: ${0##*/} [status|start|stop]" >&2
    exit 2
    ;;
esac
