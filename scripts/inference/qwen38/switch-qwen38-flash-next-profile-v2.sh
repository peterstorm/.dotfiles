#!/usr/bin/env bash
# Transactionally qualify and switch to the Qwen3.8 Flash-Next v2 candidate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

TARGET="qwen38-flash-next-fp8-vllm-v2"
IMAGE="sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1"
RUN="$SCRIPT_DIR/run-qwen38-flash-next-fp8-vllm-v2.sh"
PROBE="$SCRIPT_DIR/probe-qwen38-flash-next-determinism.sh"
MODE="${1:-status}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-3600}"

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

authenticated_models_status() {
  local key="$1"
  curl --silent --output /dev/null --write-out '%{http_code}' --config - <<EOF
url = "http://127.0.0.1:8000/v1/models"
header = "Authorization: Bearer $key"
connect-timeout = 2
max-time = 10
EOF
}

wait_for_target() {
  local deadline status key http_status
  deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
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
      http_status="$(authenticated_models_status "$key")" || http_status=000
      if [ "$http_status" = 200 ]; then
        restart_count="$(docker inspect --format '{{.RestartCount}}' "$TARGET")"
        [ "$restart_count" = 0 ] || {
          echo "error: $TARGET restarted $restart_count times during startup" >&2
          return 1
        }
        echo "HEALTHY + AUTHENTICATED + ZERO RESTARTS: $TARGET"
        return 0
      fi
      if [ "$http_status" != 000 ] && [ "$http_status" != 401 ] && [ "$http_status" != 403 ]; then
        echo "error: authenticated model probe returned HTTP $http_status" >&2
        return 1
      fi
    fi
    sleep 5
  done
  echo "error: $TARGET did not become healthy and authenticated within ${STARTUP_TIMEOUT_SECONDS}s" >&2
  return 1
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

verify_candidate_image() {
  docker run --rm --gpus all --ipc=host \
    --entrypoint python3 "$IMAGE" /opt/qwen38-v2/verify.py
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
        MODEL=qwen3.8-flash-next-fp8 "$PROBE"
        exit 0
      fi
    done
    stopped=()
    for container in "${previous[@]}"; do
      if ! inference_stop_container_if_present "$container"; then
        echo "error: profile quiesce failed; restoring already stopped profiles" >&2
        restore_profiles "${stopped[@]}" || true
        exit 1
      fi
      stopped+=("$container")
    done
    if ! verify_candidate_image; then
      echo "error: Flash-Next v2 GPU verifier failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    if ! "$RUN" --launch; then
      echo "error: Flash-Next v2 launch failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    if ! wait_for_target || ! MODEL=qwen3.8-flash-next-fp8 "$PROBE"; then
      docker logs --tail 200 "$TARGET" >&2 || true
      inference_quiesce_failed_container "$TARGET" || true
      echo "error: Flash-Next v2 acceptance failed; restoring previous profile set" >&2
      restore_profiles "${previous[@]}" || true
      exit 1
    fi
    echo "Candidate remains restart=no pending full qualification."
    ;;
  *) echo "usage: ${0##*/} {status|start|stop}" >&2; exit 2 ;;
esac
