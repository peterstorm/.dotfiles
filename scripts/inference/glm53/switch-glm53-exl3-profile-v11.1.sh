#!/usr/bin/env bash
# Safely start/stop the promoted v11.1 upstream-core-port r2.1 profile.
# v11.1 is v11 plus upstream's admission deadlock fix. The rollback target is
# v10: v11 (r2) is the release that wedges, so a failed v11.1 acceptance must
# restore whatever profile set was running before — never v11 by name. Launch
# remains transactional at restart=no; only a fully accepted target is promoted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

TARGET="glm53-flash-exl3-k4-vllm-sm120-v11.1"
EXPECTED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1"
RUN="$SCRIPT_DIR/run-glm53-flash-exl3-k4-vllm-sm120-v11.1.sh"
MODE="${1:-status}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-3600}"
KV_RECEIPT="${KV_RECEIPT:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v11.1-kv-capacity.txt}"

if ! [[ "$STARTUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: STARTUP_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

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
    if curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/health >/dev/null 2>&1; then
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

report_kv_capacity() {
  local logs kv_dtype retention protect protect_age capacity_line started_at image_id receipt_dir receipt_tmp
  logs="$(docker logs "$TARGET" 2>&1)" || return 1
  # v11.1 sizes KV from --gpu-memory-utilization like v11, so the receipt pins
  # the dtype and the cache-behaviour settings the upstream fixes are coupled
  # to — now including the r2.1 reserve aging bound — alongside this boot's
  # exact allocation.
  kv_dtype="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.kv-cache"}}')" || return 1
  [ "$kv_dtype" = fp8_ds_mla-glm-nope-528b ] || {
    echo "error: authenticated v11.1 boot reports KV dtype ${kv_dtype:-<missing>}, expected fp8_ds_mla-glm-nope-528b" >&2
    return 1
  }
  retention="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.prefix-cache-retention-interval"}}')" || return 1
  [ "$retention" = 17920 ] || {
    echo "error: FP8 KV couples retention to 17920; boot reports ${retention:-<missing>}" >&2
    return 1
  }
  protect="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.mamba-state-protect"}}')" || return 1
  protect_age="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.mamba-state-protect-age"}}')" || return 1
  capacity_line="$(grep -F 'GPU KV cache size:' <<<"$logs" | tail -n 1)"
  if [ -z "$capacity_line" ]; then
    echo "error: authenticated v11.1 boot did not emit complete KV-capacity evidence" >&2
    return 1
  fi
  started_at="$(docker inspect "$TARGET" --format '{{.State.StartedAt}}')" || return 1
  image_id="$(docker inspect "$TARGET" --format '{{.Image}}')" || return 1
  receipt_dir="$(dirname "$KV_RECEIPT")"
  install -d -m 700 "$receipt_dir"
  receipt_tmp="$(mktemp "$receipt_dir/.v11.1-kv-capacity.XXXXXX")"
  {
    printf 'container=%s\nmodel=%s\nstarted_at=%s\nimage=%s\n' \
      "$TARGET" "$EXPECTED_MODEL" "$started_at" "$image_id"
    printf 'kv_cache_dtype=%s\nprefix_cache_retention_interval=%s\nmamba_state_protect=%s\nmamba_state_protect_age=%s\n' \
      "$kv_dtype" "$retention" "$protect" "$protect_age"
    printf '%s\n' "$capacity_line"
  } >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -f "$receipt_tmp" "$KV_RECEIPT"
  printf 'KV CACHE BOOT RECEIPT (%s):\nkv_cache_dtype=%s retention=%s mamba_state_protect=%s mamba_state_protect_age=%s\n%s\n' \
    "$KV_RECEIPT" "$kv_dtype" "$retention" "$protect" "$protect_age" "$capacity_line"
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
    active=()
    [ -z "$active_output" ] || mapfile -t active <<<"$active_output"
    if [ "${#active[@]}" -eq 0 ]; then
      echo "No repository-owned inference profile is running."
    else
      printf 'running: %s\n' "${active[@]}"
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
        report_kv_capacity
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
    if ! "$RUN" --launch; then
      echo "error: multimodal FP8-DS-MLA v11.1 launch failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    if ! wait_for_target || ! report_kv_capacity || ! promote_restart_policy; then
      docker logs --tail 200 "$TARGET" >&2 || true
      inference_quiesce_failed_container "$TARGET" || true
      echo "error: multimodal FP8-DS-MLA v11.1 acceptance failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    ;;
  *) echo "usage: ${0##*/} {status|start|stop}" >&2; exit 2 ;;
esac
