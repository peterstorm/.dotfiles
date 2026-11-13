#!/usr/bin/env bash
# Safely start/stop the GLM-5.3 v16 Hyperflare TP2 profile.
# The rollback target is whatever profile set was running before (normally
# ds41-1017-native). The v15 qad2 checkpoint was deleted on 2026-11-13 to make
# room for the FP4-Local checkpoint and the Hyperflare package, so v15 needs
# its download before it can serve again.
# Launch is transactional at restart=no; only a fully accepted boot (healthy,
# authenticated, exact model id, bridge on :8011 translating) is promoted to
# restart=unless-stopped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

TARGET="glm53-flash-hyperflare-tp2-v16"
EXPECTED_MODEL="glm-5.3-flash-hyperflare-tp2-v16"
RUN="$SCRIPT_DIR/run-glm53-flash-hyperflare-tp2-v16.sh"
# The package carries compiled kernels and captured graphs; the recipe
# measured ~30 s launch-to-ready at TP2. 15 minutes covers a cold page cache.
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-900}"
BOOT_RECEIPT="${BOOT_RECEIPT:-$HOME/.local/state/glm53/flash-hyperflare-tp2-v16-boot-receipt.txt}"
MODE="${1:-status}"

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

# In-flight requests on whatever owns :8000, read from the one source that
# runtime exposes without a key: the ds4-native bridge (:8010), the
# Hyperflare bridge (:8011), or vLLM/SGLang's own /metrics. An unknown
# runtime fails closed rather than being treated as idle.
active_requests() {
  local text
  if text="$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8010/metrics 2>/dev/null)"; then
    awk '/^ds4:requests_(running|waiting)\{/ {sum += $NF} END {print sum + 0}' <<<"$text"
    return 0
  fi
  if text="$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8011/metrics 2>/dev/null)"; then
    awk '/^hyperflare:requests_(running|waiting)\{/ {sum += $NF} END {print sum + 0}' <<<"$text"
    return 0
  fi
  text="$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/metrics)" || return 1
  grep -Eq '^(vllm:num_requests_running|sglang:num_running_reqs)\{' <<<"$text" || return 1
  awk '/^(vllm:num_requests_(running|waiting)|sglang:num_(running|queue)_reqs)\{/ {sum += $NF} END {print sum + 0}' <<<"$text"
}

require_idle_endpoint() {
  local delay active
  for delay in 0 3 3; do
    sleep "$delay"
    active="$(active_requests)" || {
      echo "error: cannot read in-flight requests of the active profile; refusing cutover" >&2
      return 1
    }
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

# The bridge is part of acceptance: a profile the dashboards and the ledger
# cannot see is not done.
require_metrics_bridge() {
  local text
  text="$(curl -fsS --connect-timeout 2 --max-time 10 http://127.0.0.1:8011/metrics)" || {
    echo "error: Hyperflare metrics bridge on :8011 is not serving (systemctl status hyperflare-metrics)" >&2
    return 1
  }
  grep -Fq "hyperflare:model_info{model_name=\"$EXPECTED_MODEL\"} 1" <<<"$text" || {
    echo "error: bridge on :8011 does not report model $EXPECTED_MODEL" >&2
    return 1
  }
  echo "METRICS BRIDGE: :8011 reports $EXPECTED_MODEL"
}

report_boot_receipt() {
  local logs image_id started_at package receipt_dir receipt_tmp capacity_lines
  logs="$(docker logs "$TARGET" 2>&1)" || return 1
  image_id="$(docker inspect "$TARGET" --format '{{.Image}}')" || return 1
  started_at="$(docker inspect "$TARGET" --format '{{.State.StartedAt}}')" || return 1
  package="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.package"}}')" || return 1
  # Recipe: "Plan cache. per GPU: 86.56 GiB loaded · 7.71 GiB cache budget" and
  # "Allocate cache. 15.4 GiB · 2231808 KV tokens · ..." at TP2.
  capacity_lines="$(grep -E 'Plan cache\.|Allocate cache\.|Start server\.' <<<"$logs" | tail -n 6)"
  receipt_dir="$(dirname "$BOOT_RECEIPT")"
  install -d -m 700 "$receipt_dir"
  receipt_tmp="$(mktemp "$receipt_dir/.v16-boot-receipt.XXXXXX")"
  {
    printf 'container=%s\nmodel=%s\npackage=%s\nstarted_at=%s\nimage=%s\n' \
      "$TARGET" "$EXPECTED_MODEL" "$package" "$started_at" "$image_id"
    printf '%s\n' '--- capacity lines ---'
    printf '%s\n' "${capacity_lines:-<none captured>}"
  } >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv -f "$receipt_tmp" "$BOOT_RECEIPT"
  printf 'BOOT RECEIPT: %s (model=%s, package=%s)\n' "$BOOT_RECEIPT" "$EXPECTED_MODEL" "$package"
  [ -n "$capacity_lines" ] || echo "WARNING: no capacity line captured; inspect docker logs $TARGET" >&2
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
        require_metrics_bridge
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
    if ! "$RUN" --launch; then
      echo "error: Hyperflare v16 launch failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    if ! wait_for_target || ! require_metrics_bridge || ! report_boot_receipt || ! promote_restart_policy; then
      docker logs --tail 200 "$TARGET" >&2 || true
      inference_quiesce_failed_container "$TARGET" || true
      echo "error: Hyperflare v16 acceptance failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    ;;
  *) echo "usage: ${0##*/} {status|start|stop}" >&2; exit 2 ;;
esac
