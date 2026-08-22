#!/usr/bin/env bash
# Safely prepare or release a maximum-quality MiniMax H3 model family.
set -euo pipefail

COMFYUI_URL="${COMFYUI_URL:-http://127.0.0.1:8188}"
STATE_DIR="${H3_PHASE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/comfyui-h3-phase}"
MARKER="$STATE_DIR/active-family"
LOCK="$STATE_DIR/phase.lock"

usage() {
  cat <<'EOF'
Usage:
  h3-model-phase status
  h3-model-phase prepare <fl2va|ref2va>
  h3-model-phase release

prepare and release fail unless ComfyUI's running and pending queues are empty.
Workflow loader nodes load the selected family on demand. release calls ComfyUI's
native /free endpoint only after the completed job is idle.
EOF
}

require_loopback_url() {
  local port
  if [[ ! "$COMFYUI_URL" =~ ^http://(127\.0\.0\.1|localhost):([0-9]{1,5})$ ]]; then
    echo "error: COMFYUI_URL must use loopback HTTP with an explicit port: $COMFYUI_URL" >&2
    return 1
  fi
  port="${BASH_REMATCH[2]}"
  if ((10#$port < 1 || 10#$port > 65535)); then
    echo "error: COMFYUI_URL port is outside 1-65535: $port" >&2
    return 1
  fi
}

queue_json() {
  curl --fail --silent --show-error "$COMFYUI_URL/queue"
}

queue_counts() {
  jq -er '
    if (.queue_running | type) != "array" or (.queue_pending | type) != "array"
    then error("malformed ComfyUI queue response")
    else "\(.queue_running | length) \(.queue_pending | length)"
    end
  '
}

read_queue_counts() {
  queue_json | queue_counts
}

assert_idle() {
  local running pending
  read -r running pending < <(read_queue_counts)
  if [ "$running" -ne 0 ] || [ "$pending" -ne 0 ]; then
    echo "error: refusing model release while ComfyUI is busy (running=$running pending=$pending)" >&2
    return 1
  fi
}

free_models() {
  curl --fail --silent --show-error \
    -H 'Content-Type: application/json' \
    --data '{"unload_models":true,"free_memory":true}' \
    "$COMFYUI_URL/free" >/dev/null
}

active_family() {
  if [ -s "$MARKER" ]; then
    tr -d '\r\n' <"$MARKER"
  else
    printf '%s' none
  fi
}

write_family() {
  local family="$1" temporary="$MARKER.new"
  printf '%s\n' "$family" >"$temporary"
  chmod 0600 "$temporary"
  mv -f "$temporary" "$MARKER"
}

status() {
  local running pending
  read -r running pending < <(read_queue_counts)
  printf 'H3_PHASE_STATUS family=%s running=%s pending=%s\n' \
    "$(active_family)" "$running" "$pending"
}

prepare() {
  local family="${1:-}"
  case "$family" in
    fl2va | ref2va) ;;
    *)
      echo "error: family must be fl2va or ref2va" >&2
      return 2
      ;;
  esac
  assert_idle
  free_models
  assert_idle
  write_family "$family"
  printf 'H3_PHASE_READY family=%s; queue only the matching BF16 workflow\n' "$family"
}

release() {
  assert_idle
  free_models
  assert_idle
  rm -f "$MARKER"
  echo 'H3_PHASE_RELEASED family=none'
}

main() {
  local command="${1:-}"
  require_loopback_url
  for dependency in curl jq flock; do
    command -v "$dependency" >/dev/null 2>&1 || {
      echo "error: required command is unavailable: $dependency" >&2
      return 1
    }
  done
  install -d -m 0700 "$STATE_DIR"
  exec 9>"$LOCK"
  flock -x 9

  case "$command" in
    status)
      [ "$#" -eq 1 ] || { usage >&2; return 2; }
      status
      ;;
    prepare)
      [ "$#" -eq 2 ] || { usage >&2; return 2; }
      prepare "$2"
      ;;
    release)
      [ "$#" -eq 1 ] || { usage >&2; return 2; }
      release
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
