#!/usr/bin/env bash
# Safely start/stop the unpromoted graph-enabled v10 candidate with rollback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

TARGET="glm53-flash-exl3-k4-vllm-sm120-v10"
EXPECTED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10"
RUN="$SCRIPT_DIR/run-glm53-flash-exl3-k4-vllm-sm120-v10.sh"
MODE="${1:-status}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-3600}"
KV_RECEIPT="${KV_RECEIPT:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v10-kv-capacity.txt}"

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
  local logs kv_bytes memory_line capacity_line started_at image_id receipt_dir receipt_tmp
  logs="$(docker logs "$TARGET" 2>&1)" || return 1
  kv_bytes="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.kv-cache-memory-bytes-per-gpu"}}')" || return 1
  [ "$kv_bytes" = 3758096384 ] || {
    echo "error: authenticated v10 boot reports KV budget ${kv_bytes:-<missing>}, expected 3758096384" >&2
    return 1
  }
  memory_line="Configured KV cache memory: $kv_bytes bytes per GPU (3.5 GiB)"
  capacity_line="$(grep -F 'GPU KV cache size:' <<<"$logs" | tail -n 1)"
  if [ -z "$capacity_line" ]; then
    echo "error: authenticated v10 boot did not emit complete KV-capacity evidence" >&2
    return 1
  fi
  started_at="$(docker inspect "$TARGET" --format '{{.State.StartedAt}}')" || return 1
  image_id="$(docker inspect "$TARGET" --format '{{.Image}}')" || return 1
  receipt_dir="$(dirname "$KV_RECEIPT")"
  install -d -m 700 "$receipt_dir"
  receipt_tmp="$(mktemp "$receipt_dir/.v10-kv-capacity.XXXXXX")"
  {
    printf 'container=%s\nmodel=%s\nstarted_at=%s\nimage=%s\n' \
      "$TARGET" "$EXPECTED_MODEL" "$started_at" "$image_id"
    printf '%s\n%s\n' "$memory_line" "$capacity_line"
  } >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -f "$receipt_tmp" "$KV_RECEIPT"
  printf 'KV CACHE BOOT RECEIPT (%s):\n%s\n%s\n' \
    "$KV_RECEIPT" "$memory_line" "$capacity_line"
}

retain_candidate_restart_policy() {
  local restart_policy
  restart_policy="$(docker inspect "$TARGET" --format '{{.HostConfig.RestartPolicy.Name}}')" || return 1
  [ "$restart_policy" = no ] || {
    echo "error: unpromoted v10 candidate restart policy is $restart_policy, expected no" >&2
    return 1
  }
  echo "UNPROMOTED: restart=no retained pending equivalence and soak gates"
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
        retain_candidate_restart_policy
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
      echo "error: multimodal FP8-DS-MLA v10 launch failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    if ! wait_for_target || ! report_kv_capacity || ! retain_candidate_restart_policy; then
      docker logs --tail 200 "$TARGET" >&2 || true
      inference_quiesce_failed_container "$TARGET" || true
      echo "error: multimodal FP8-DS-MLA v10 acceptance failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    ;;
  *) echo "usage: ${0##*/} {status|start|stop}" >&2; exit 2 ;;
esac
