#!/usr/bin/env bash
# Stop the Hyperflare GLM primaries, wait for both GPUs to go idle, then export
# a variant's package — detached, so an ssh drop or a short-lived driver cannot
# kill a 15-minute export mid-flight.
#
# Why this exists: the export wrapper refuses to run while a serving profile
# holds GPU memory, and every attempt to drive "stop the primary, then export"
# over an ssh session died with the session (the pipeline gets SIGHUP'd) or was
# cut off by the driver's own timeout. This script is meant to run ON desktop
# under setsid/nohup with stdin detached:
#
#   ssh desktop 'setsid nohup bash /tmp/stop-and-export-glm53-hyperflare.sh \
#       cyber-hybrid-bf16 > /tmp/glm-export-cyber-hybrid-bf16.driver.log 2>&1 < /dev/null &'
#
# It then records every phase in a status file the operator polls:
#
#   /tmp/glm-export-<variant>.status   one "timestamp phase" line per step
#   /tmp/glm-export-<variant>.log      the export wrapper's full output
#
# Scope discipline: it stops ONLY containers named glm53-flash-hyperflare-tp2-*
# (the GLM primaries this repository owns — v16, cyber-hybrid, cyber-hybrid-bf16
# and a leftover export container). It never touches the ds4-native primaries,
# comfyui or anything else; if some other workload holds GPU memory when the
# deadline expires it fails closed with nvidia-smi's answer instead of killing
# processes it does not own. The export itself runs with no timeout: it either
# finishes, or fails and records why.
#
# Usage: stop-and-export-glm53-hyperflare.sh VARIANT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Overridable for tests; the real commands on desktop.
DOCKER="${DOCKER:-docker}"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
GPU_LIMIT_MIB="${GPU_LIMIT_MIB:-1024}"     # the export wrapper's own idle gate
GPU_WAIT_SECONDS="${GPU_WAIT_SECONDS:-600}" # deadline for the GPUs to go idle
POLL_SECONDS="${POLL_SECONDS:-5}"
IDLE_CHECKS="${IDLE_CHECKS:-3}"             # consecutive idle polls before proceeding

status() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATUS_FILE"; }

stop_primaries() {
  local running name
  running="$("$DOCKER" ps --format '{{.Names}}' 2>/dev/null | grep -E '^glm53-flash-hyperflare-tp2-' || true)"
  if [ -z "$running" ]; then
    status "no hyperflare primaries were running"
    return 0
  fi
  for name in $running; do
    status "stopping $name"
    "$DOCKER" stop -t 120 "$name" >/dev/null || { status "failed to stop $name"; return 1; }
  done
}

gpu_used_mib() {
  "$NVIDIA_SMI" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' '
}

# True once every GPU has reported at most GPU_LIMIT_MIB MiB for IDLE_CHECKS
# consecutive polls. A failing nvidia-smi counts as busy and retries.
await_idle_gpus() {
  local deadline=$((SECONDS + GPU_WAIT_SECONDS)) consecutive=0 used
  while (( SECONDS < deadline )); do
    used="$(gpu_used_mib 2>/dev/null)" || used=""
    if [ "$(printf '%s\n' "$used" | grep -c .)" -ge 2 ] \
       && ! printf '%s\n' "$used" | grep -qvE '^[0-9]+$' \
       && printf '%s\n' "$used" | awk -v lim="$GPU_LIMIT_MIB" '$1 > lim { exit 1 }'; then
      consecutive=$((consecutive + 1))
      if (( consecutive >= IDLE_CHECKS )); then
        return 0
      fi
    else
      consecutive=0
    fi
    sleep "$POLL_SECONDS"
  done
  status "gpus still busy: $(printf '%s' "$used" | tr '\n' ' ')"
  return 1
}

main() {
  local variant="${1:-}"
  if [ -z "$variant" ]; then
    echo "usage: ${0##*/} VARIANT" >&2
    return 2
  fi
  VARIANT="$variant"
  STATUS_FILE="${STATUS_FILE:-/tmp/glm-export-$VARIANT.status}"
  LOG="${LOG:-/tmp/glm-export-$VARIANT.log}"
  EXPORT_WRAPPER="${EXPORT_WRAPPER:-$SCRIPT_DIR/export-glm53-flash-hyperflare-tp2-v16.sh}"
  : > "$STATUS_FILE"
  status "driver start (variant $VARIANT)"

  stop_primaries
  status "waiting for idle GPUs"
  if ! await_idle_gpus; then
    status "aborted: GPUs never went idle; nothing was exported"
    return 1
  fi

  status "export starting (log $LOG)"
  local rc=0
  VARIANT="$VARIANT" "$EXPORT_WRAPPER" >>"$LOG" 2>&1 || rc=$?
  if (( rc == 0 )); then
    status "done $(sed -n 's/^PACKAGE OK: //p' "$LOG" | tail -1)"
    return 0
  fi
  status "failed exit=$rc (see $LOG)"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
