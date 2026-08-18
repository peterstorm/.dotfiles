#!/usr/bin/env bash
# Switch the Qwen3.8-27B DSpark backend on :8000 between SGLang and vLLM.
#
#   bash scripts/inference/qwen38/switch-qwen38-backend.sh status    # who owns :8000, is it healthy
#   bash scripts/inference/qwen38/switch-qwen38-backend.sh vllm      # stop SGLang DSpark, start vLLM DSpark
#   bash scripts/inference/qwen38/switch-qwen38-backend.sh sglang    # the reverse
#
# The cutover is a hard stop: :8000 is down between container stop and first
# healthy response (a cold vLLM start takes minutes — kernel compile + CUDA
# graphs). Anything riding on desktop-vllm (pi sessions, probes) loses
# in-flight requests and reconnects once health is green; the served model
# name, key, and endpoint are identical across both profiles, so no client
# changes are needed. Run this on the desktop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
VLLM_NAME="qwen38-27b-bf16-dspark-vllm"
VLLM_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dspark-vllm.sh"
SGLANG_NAME="qwen38-27b-bf16-dspark-sglang"
SGLANG_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dspark-sglang.sh"
HEALTH_URL="http://127.0.0.1:8000/health"
MODELS_URL="http://127.0.0.1:8000/v1/models"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1200}" # cold-start budget in seconds

case "${1:-}" in
  status|vllm|sglang) ;;
  *) echo "usage: $0 {status|vllm|sglang}" >&2; exit 2 ;;
esac
MODE="${1:-status}"

running_name() {
  local n
  for n in "$VLLM_NAME" "$SGLANG_NAME"; do
    if docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null | grep -q true; then
      printf '%s\n' "$n"
      return 0
    fi
  done
  return 1
}

port_bound() {
  command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8000' | grep -q .
}

authenticated_status() {
  local url="$1" key escaped_key
  if ! inference_resolve_client_keyfile; then
    printf '%s\n' missing-key
    return 0
  fi
  key="$(<"$INFERENCE_CLIENT_KEYFILE")"
  if ! inference_validate_api_key "$key"; then
    printf '%s\n' invalid-key
    return 0
  fi
  escaped_key="${key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"

  # Read the header through curl's stdin config so the key never enters argv.
  # Do not use --fail: callers need to distinguish auth rejection from 5xx or I/O.
  {
    printf '%s\n' \
      'silent' \
      'output = "/dev/null"' \
      'write-out = "%{http_code}"' \
      'max-time = 3' \
      "url = \"$url\""
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_key"
  } | curl --config - || true
}

server_healthy() {
  local status
  if curl -fsS -m 3 "$HEALTH_URL" >/dev/null 2>&1; then
    return 0
  fi
  status="$(authenticated_status "$HEALTH_URL" 2>/dev/null)"
  [ "$status" = 200 ]
}

if [ "$MODE" = "status" ]; then
  current="$(running_name || true)"
  echo "backend container: ${current:-none}"
  if server_healthy; then
    echo "health: OK"
    auth_status="$(authenticated_status "$MODELS_URL" 2>/dev/null)"
    case "$auth_status" in
      200) echo "client authentication: OK" ;;
      401|403) echo "client authentication: REJECTED (server key differs from Pi's desktop-user key)" ;;
      *) echo "client authentication: INDETERMINATE (HTTP/status $auth_status)" ;;
    esac
  else
    echo "health: DOWN (or still starting)"
  fi
  metrics="$(curl -fsS -m 3 http://127.0.0.1:8000/metrics 2>/dev/null || true)"
  spec_line="$(grep -m1 -E '^vllm:spec_decode_num_drafts |^sglang:spec_accept_length' <<<"$metrics" || true)"
  [ -n "$spec_line" ] && echo "spec decode: $spec_line"
  exit 0
fi

if [ "$MODE" = "vllm" ]; then
  START_NAME="$VLLM_NAME"; START_SCRIPT="$VLLM_SCRIPT"
else
  START_NAME="$SGLANG_NAME"; START_SCRIPT="$SGLANG_SCRIPT"
fi

wait_until_healthy() {
  local started_at now elapsed last_log
  echo "Waiting for $HEALTH_URL (budget $((HEALTH_TIMEOUT / 60)) min) ..."
  started_at="$(date +%s)"
  while :; do
    if server_healthy; then
      return 0
    fi
    now="$(date +%s)"
    elapsed=$((now - started_at))
    if [ "$elapsed" -ge "$HEALTH_TIMEOUT" ]; then
      echo "error: $START_NAME not healthy after $((HEALTH_TIMEOUT / 60)) min" >&2
      echo "Last log lines:" >&2
      docker logs --tail 30 "$START_NAME" 2>&1 | tail -30 >&2 || true
      echo "Recovery: bash $0 $( [ "$MODE" = vllm ] && echo sglang || echo vllm )" >&2
      return 1
    fi
    last_log="$(docker logs --tail 1 "$START_NAME" 2>&1 | tail -1 | cut -c1-160 || true)"
    echo "  [${elapsed}s] ${last_log}"
    sleep 15
  done
}

stop_backend() {
  local name="$1" waited=0
  echo "Stopping $name ..."
  docker stop -t 30 "$name"
  while port_bound && [ "$waited" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if port_bound; then
    echo "error: port 8000 is still bound after stopping $name" >&2
    return 1
  fi
  echo "Port 8000 free."
}

current="$(running_name || true)"
if [ "$current" = "$START_NAME" ]; then
  echo "$START_NAME is already running; waiting for readiness before checking its key."
  wait_until_healthy
  auth_status="$(authenticated_status "$MODELS_URL" 2>/dev/null)"
  case "$auth_status" in
    200)
      echo "$START_NAME accepts Pi's desktop-user key."
      exit 0
      ;;
    401|403)
      echo "$START_NAME rejects Pi's desktop-user key; restarting with the synchronized key."
      ;;
    *)
      echo "error: cannot verify $START_NAME authentication (HTTP/status $auth_status); refusing a speculative restart" >&2
      exit 1
      ;;
  esac
fi

if [ -n "$current" ]; then
  stop_backend "$current"
fi

echo "Starting $START_NAME (cold start can take several minutes) ..."
bash "$START_SCRIPT"
wait_until_healthy

auth_status="$(authenticated_status "$MODELS_URL" 2>/dev/null)"
case "$auth_status" in
  200) ;;
  401|403)
    echo "error: $START_NAME is healthy but rejects the synchronized desktop-user key (HTTP $auth_status)" >&2
    exit 1
    ;;
  *)
    echo "error: $START_NAME is healthy but API authentication is indeterminate (HTTP/status $auth_status)" >&2
    exit 1
    ;;
esac

echo
echo "HEALTHY + AUTHENTICATED: $START_NAME is serving qwen3.8-27b on :8000."
if [ "$MODE" = "vllm" ]; then
  echo "Verify the draft routed to the Qwen implementation (second line must read Qwen3DSparkModel):"
  echo "  docker logs $START_NAME 2>&1 | grep 'Resolved architecture' | head -2"
  echo "Verify spec decode is actually drafting:"
  echo "  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^vllm:spec_decode_num_(drafts|accepted)' | head -4"
fi
echo "Acceptance appears in the Grafana DSpark panels (legend switches to '$MODE')."
echo "Anything that was mid-request during the cutover: just resend it."
