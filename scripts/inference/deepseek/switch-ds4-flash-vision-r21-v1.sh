#!/usr/bin/env bash
# Transactionally start the DS4 Vision r21 candidate and restore prior profiles on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

TARGET="ds4-flash-vision-infernal-invocation-cu133-r21-v1"
EXPECTED_MODEL="deepseek-v4-flash-vision"
RUN="$SCRIPT_DIR/run-ds4-flash-vision-r21-v1.sh"
PROBE="$SCRIPT_DIR/probe-ds4-flash-vision-r21-v1.sh"
MODE="${1:-status}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-3600}"

[[ "$STARTUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: STARTUP_TIMEOUT_SECONDS must be positive" >&2
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

restore_profiles() {
  local container failed=0
  for container in "$@"; do
    if docker start "$container" >/dev/null; then
      echo "rollback restarted: $container"
    else
      echo "error: rollback could not restart $container" >&2
      failed=1
    fi
  done
  return "$failed"
}

wait_for_target() {
  local deadline key response restart_count
  deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if ! inference_container_running "$TARGET"; then
      echo "error: $TARGET exited during startup" >&2
      return 1
    fi
    if curl -fsS --connect-timeout 2 --max-time 5 \
      http://127.0.0.1:8000/health >/dev/null 2>&1; then
      inference_resolve_client_keyfile || return 1
      key="$(<"$INFERENCE_CLIENT_KEYFILE")"
      response="$(curl -fsS --config - <<EOF
url = "http://127.0.0.1:8000/v1/models"
header = "Authorization: Bearer $key"
max-time = 10
EOF
)" || response=''
      if jq -e --arg model "$EXPECTED_MODEL" \
        '.data | any(.id == $model)' <<<"$response" >/dev/null 2>&1; then
        docker inspect "$TARGET" --format '{{json .Config.Env}}' | jq -e '
          any(. == "MODE=dspark") and any(. == "DSPARK_TOKENS=6")
        ' >/dev/null || {
          echo "error: $TARGET is not the qualified fixed-K6 profile" >&2
          return 1
        }
        restart_count="$(docker inspect "$TARGET" --format '{{.RestartCount}}')"
        [[ "$restart_count" == 0 ]] || {
          echo "error: $TARGET restarted $restart_count times" >&2
          return 1
        }
        echo "HEALTHY + AUTHENTICATED + ZERO RESTARTS: $TARGET"
        return 0
      fi
    fi
    sleep 5
  done
  echo "error: startup timed out after ${STARTUP_TIMEOUT_SECONDS}s" >&2
  return 1
}

case "$MODE" in
  status)
    output="$(running_profiles)" || exit $?
    [[ -z "$output" ]] && echo "No repository-owned inference profile is running." \
      || printf 'running: %s\n' "$output"
    ;;
  stop)
    inference_stop_container_if_present "$TARGET"
    echo "Stopped $TARGET if present."
    ;;
  start)
    "$RUN" --preflight
    output="$(running_profiles)" || exit $?
    previous=()
    [[ -z "$output" ]] || mapfile -t previous <<<"$output"
    if printf '%s\n' "${previous[@]}" | grep -Fxq "$TARGET"; then
      wait_for_target
      "$PROBE"
      exit 0
    fi

    stopped=()
    for container in "${previous[@]}"; do
      if inference_stop_container_if_present "$container"; then
        stopped+=("$container")
      else
        restore_profiles "${stopped[@]}" || true
        exit 1
      fi
    done

    if ! "$RUN" --launch || ! wait_for_target || ! "$PROBE"; then
      docker logs --tail 300 "$TARGET" >&2 2>/dev/null || true
      inference_quiesce_failed_container "$TARGET" || true
      echo "error: DS4 Vision acceptance failed; restoring previous profiles" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    echo "DS4 Vision remains restart=no after target and required fixed-K6 qualification."
    ;;
  *) echo "usage: ${0##*/} {status|start|stop}" >&2; exit 2 ;;
esac
