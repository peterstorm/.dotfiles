#!/usr/bin/env bash
# Switch the Qwen3.8-27B DSpark/DFlash2 server on :8000 across the five
# 08-16/v2 backend containers. V2-first: the default backends are the
# 2026-08-18 v2 profiles (DSpark draft pinned to 85ef153, vLLM image
# aa99034); 'dflash2' is the 2026-08-19 SGLang profile with the DFlash 2
# draft (z-lab/Qwen3.8-27B-DFlash2, block size 8).
#
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh status      # who owns :8000, is it healthy
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh vllm        # -> vLLM v2
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh sglang      # -> SGLang v2 (DSpark draft)
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2     # -> SGLang v2 (DFlash 2 draft, surgery/v1 fork image)
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native # -> SGLang (REAL DFlash 2, PR #35371 merge image, BF16 TP2)
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-vllm   # -> vLLM (DFlash 2, PR #52816 image, BF16 TP2)
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh v1-vllm     # -> vLLM 08-16 (rollback)
#   bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh v1-sglang   # -> SGLang 08-16 (rollback)
#
# Supersedes switch-qwen38-backend.sh, which only knows the v1 containers and
# cannot stop a running -v2 profile. Same hard-stop cutover semantics: :8000
# is down between container stop and first healthy response (a cold vLLM
# start takes minutes — kernel compile + CUDA graphs). Anything riding on
# desktop-vllm (pi sessions, probes) loses in-flight requests and reconnects
# once health is green; the served model name, key, and endpoint are
# identical across all four profiles, so no client changes are needed.
# Run this on the desktop.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"

VLLM_V2_NAME="qwen38-27b-bf16-dspark-vllm-v2"
VLLM_V2_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dspark-vllm-v2.sh"
SGLANG_V2_NAME="qwen38-27b-bf16-dspark-sglang-v2"
SGLANG_V2_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dspark-sglang-v2.sh"
VLLM_V1_NAME="qwen38-27b-bf16-dspark-vllm"
VLLM_V1_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dspark-vllm.sh"
SGLANG_V1_NAME="qwen38-27b-bf16-dspark-sglang"
SGLANG_V1_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dspark-sglang.sh"
DFLASH2_SGLANG_NAME="qwen38-27b-bf16-dflash2-sglang"
DFLASH2_SGLANG_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-sglang.sh"
DFLASH2_NATIVE_NAME="qwen38-27b-bf16-dflash2-sglang-native"
DFLASH2_NATIVE_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-sglang-native.sh"
DFLASH2_VLLM_NAME="qwen38-27b-bf16-dflash2-vllm"
DFLASH2_VLLM_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-vllm.sh"
ALL_NAMES=("$VLLM_V2_NAME" "$SGLANG_V2_NAME" "$DFLASH2_SGLANG_NAME" "$DFLASH2_NATIVE_NAME" "$DFLASH2_VLLM_NAME" "$VLLM_V1_NAME" "$SGLANG_V1_NAME")

HEALTH_URL="http://127.0.0.1:8000/health"
MODELS_URL="http://127.0.0.1:8000/v1/models"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-1200}" # cold-start budget in seconds

case "${1:-}" in
  status|vllm|sglang|dflash2|v1-vllm|v1-sglang|dflash2-native|dflash2-vllm) ;;
  *) echo "usage: $0 {status|vllm|sglang|dflash2|v1-vllm|v1-sglang|dflash2-native|dflash2-vllm}" >&2; exit 2 ;;
esac
MODE="${1:-status}"

is_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

running_names() {
  local n found=0
  for n in "${ALL_NAMES[@]}"; do
    if is_running "$n"; then
      printf '%s\n' "$n"
      found=1
    fi
  done
  return $((1 - found))
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
  mapfile -t current < <(running_names || true)
  echo "backend container: ${current[*]:-none}"
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
  spec_line="$(grep -m1 -E '^vllm:spec_decode_num_drafts_total\{|^sglang:spec_accept_length' <<<"$metrics" || true)"
  [ -n "$spec_line" ] && echo "spec decode: $spec_line"
  exit 0
fi

case "$MODE" in
  vllm)     START_NAME="$VLLM_V2_NAME";   START_SCRIPT="$VLLM_V2_SCRIPT" ;;
  sglang)   START_NAME="$SGLANG_V2_NAME"; START_SCRIPT="$SGLANG_V2_SCRIPT" ;;
  dflash2)  START_NAME="$DFLASH2_SGLANG_NAME"; START_SCRIPT="$DFLASH2_SGLANG_SCRIPT" ;;
  dflash2-native) START_NAME="$DFLASH2_NATIVE_NAME"; START_SCRIPT="$DFLASH2_NATIVE_SCRIPT" ;;
  dflash2-vllm) START_NAME="$DFLASH2_VLLM_NAME"; START_SCRIPT="$DFLASH2_VLLM_SCRIPT" ;;
  v1-vllm)  START_NAME="$VLLM_V1_NAME";   START_SCRIPT="$VLLM_V1_SCRIPT" ;;
  v1-sglang) START_NAME="$SGLANG_V1_NAME"; START_SCRIPT="$SGLANG_V1_SCRIPT" ;;
esac

# Same-engine profile on the other side of the v1/v2 line — the fallback a
# failed cutover suggests. dflash2 falls back to the DSpark-draft SGLang
# profile (same engine, previous-generation draft).
case "$MODE" in
  vllm) FALLBACK="v1-vllm" ;;
  sglang) FALLBACK="v1-sglang" ;;
  dflash2) FALLBACK="sglang" ;;
  dflash2-native) FALLBACK="dflash2" ;;
  dflash2-vllm) FALLBACK="vllm" ;;
  v1-vllm) FALLBACK="vllm" ;;
  v1-sglang) FALLBACK="sglang" ;;
esac

wait_until_healthy() {
  local started_at now elapsed last_log container_state container_status restart_count
  echo "Waiting for $HEALTH_URL (budget $((HEALTH_TIMEOUT / 60)) min) ..."
  started_at="$(date +%s)"
  while :; do
    container_state="$(docker inspect --format='{{.State.Status}} {{.RestartCount}}' "$START_NAME" 2>/dev/null || true)"
    read -r container_status restart_count <<< "$container_state"
    if [ "$container_status" != running ] || ! [[ "$restart_count" =~ ^[0-9]+$ ]] || [ "$restart_count" -gt 0 ]; then
      echo "error: $START_NAME failed during startup (status=${container_status:-missing}, restarts=${restart_count:-unknown})" >&2
      echo "Last log lines:" >&2
      docker logs --tail 30 "$START_NAME" 2>&1 | tail -30 >&2 || true
      # Stop Docker from repeating a deterministic startup failure while the
      # operator inspects the preserved container and logs.
      docker update --restart=no "$START_NAME" >/dev/null 2>&1 || true
      docker stop -t 10 "$START_NAME" >/dev/null 2>&1 || true
      echo "Recovery: bash $0 $FALLBACK" >&2
      return 1
    fi
    if server_healthy; then
      return 0
    fi
    now="$(date +%s)"
    elapsed=$((now - started_at))
    if [ "$elapsed" -ge "$HEALTH_TIMEOUT" ]; then
      echo "error: $START_NAME not healthy after $((HEALTH_TIMEOUT / 60)) min" >&2
      echo "Last log lines:" >&2
      docker logs --tail 30 "$START_NAME" 2>&1 | tail -30 >&2 || true
      echo "Recovery: bash $0 $FALLBACK" >&2
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

mapfile -t current < <(running_names || true)

if [ "${#current[@]}" -gt 1 ]; then
  echo "error: multiple DSpark containers are running: ${current[*]}" >&2
  echo "This should not happen (they share :8000). Stop the extras manually before switching." >&2
  exit 1
fi

if [ -n "${current[0]:-}" ] && [ "${current[0]}" = "$START_NAME" ]; then
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

if [ -n "${current[0]:-}" ]; then
  stop_backend "${current[0]}"
elif port_bound; then
  echo "error: port 8000 is bound but no DSpark container is running" >&2
  echo "(typically the DeepSeek-V4-Flash server: docker stop ds4-0731-r33) — stop it explicitly first." >&2
  exit 1
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
case "$START_NAME" in
  *dflash2*vllm*)
    echo "Verify the target and draft resolved to native Qwen3.8/DFlash 2 implementations:"
    echo "  docker logs $START_NAME 2>&1 | grep 'Resolved architecture' | head -2"
    echo "  # expected: Qwen3_5ForConditionalGeneration, then DFlash2Qwen3ForCausalLM"
    echo "Verify spec decode is actually drafting:"
    echo "  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^vllm:spec_decode_num_(drafts|accepted)' | head -4"
    ;;
  *vllm*)
    echo "Verify the draft routed to the Qwen implementation (second line must read Qwen3DSparkModel):"
    echo "  docker logs $START_NAME 2>&1 | grep 'Resolved architecture' | head -2"
    echo "Verify spec decode is actually drafting:"
    echo "  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^vllm:spec_decode_num_(drafts|accepted)' | head -4"
    ;;
  *dflash2*)
    echo "Verify spec decode is actually drafting (acceptance length near 4.1-5.5;"
    echo "the DFlash 2 card beats DSpark's 3.0-4.4 on the same benchmarks; near 1.0 means miswired):"
    echo "  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_' | head -4"
    ;;
  *)
    echo "Verify spec decode is actually drafting:"
    echo "  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_(accept_length|draft)' | head -4"
    ;;
esac
echo "Acceptance appears in the Grafana DSpark panels."
echo "Anything that was mid-request during the cutover: just resend it."
