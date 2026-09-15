#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/comfyui-tunnel.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$SCRIPT" ] || fail "comfyui-tunnel.sh must be executable"
sh -n "$SCRIPT" || fail "comfyui-tunnel.sh has invalid shell syntax"
grep -Fq 'ExitOnForwardFailure=yes' "$SCRIPT" \
  || fail "tunnel must fail if local port forwarding cannot bind"
grep -Fq -- '-L 8188:127.0.0.1:8188' "$SCRIPT" \
  || fail "tunnel must forward local 8188 to desktop loopback 8188"
grep -Fq '  desktop' "$SCRIPT" \
  || fail "tunnel must use the configured desktop SSH host"

printf 'PASS: ComfyUI SSH tunnel contract\n'
