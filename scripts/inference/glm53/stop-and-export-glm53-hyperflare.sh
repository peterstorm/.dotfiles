#!/usr/bin/env bash
# Stop the Hyperflare GLM primaries, wait for both GPUs to go idle, then export
# a variant's package — detached, so an ssh drop or a short-lived driver cannot
# kill a 15-minute export mid-flight.
#
# Why this exists: the export wrapper refuses to run while a serving profile
# holds GPU memory, and every attempt to drive "stop the primary, then export"
# over an ssh session died with the session (the pipeline gets SIGHUP'd) or was
# cut off by the driver's own timeout. This script runs ON desktop under
# setsid/nohup with stdin detached. Start it with launch-glm53-export.sh, which
# ships a committed snapshot of this whole directory and runs it from there:
#
#   scripts/inference/glm53/launch-glm53-export.sh cyber-hybrid-bf16
#
# Never copy this script anywhere on its own: it runs the export wrapper and the
# variant table that sit NEXT TO IT. On 2026-11-15 a lone copy in /tmp found a
# stale pre-variant wrapper there (one that ignores VARIANT and would have
# exported v16's checkpoint under the bf16 receipt), stopped v16, then failed.
#
# It records every phase in a status file the operator polls:
#
#   /tmp/glm-export-<variant>.status   one "timestamp phase" line per step
#   /tmp/glm-export-<variant>.log      the export wrapper's full output
#
# Preflight comes before any stop: the variant table the wrapper will source,
# the variant, the checkpoint and the disk headroom for the package are checked
# while the serving primary is still up, and a failure leaves it untouched.
#
# Scope discipline: it stops ONLY containers named glm53-flash-hyperflare-tp2-*
# (the GLM primaries this repository owns — v16, cyber-hybrid, cyber-hybrid-bf16
# and a leftover export container). It never touches the ds4-native primaries,
# comfyui or anything else; if some other workload holds GPU memory when the
# deadline expires it fails closed with nvidia-smi's answer instead of killing
# processes it does not own. The export itself runs with no timeout: it either
# finishes, or fails and records why.
#
# Whatever happens after the stop -- the GPUs never go idle, the export fails, or
# it succeeds -- the primaries it stopped are started again before the terminal
# status line, so the endpoint is down only while the export holds the GPUs (on
# 2026-11-15 a refused export left it dark until someone noticed). Cutting over
# to the new package is the switch script's job; it stops them again first.
#
# Usage: stop-and-export-glm53-hyperflare.sh VARIANT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Overridable for tests; the real commands and paths on desktop.
DOCKER="${DOCKER:-docker}"
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
ROOT_HOST="${ROOT_HOST:-/models/glm53-hyperflare}" # the export wrapper's state root
GPU_LIMIT_MIB="${GPU_LIMIT_MIB:-1024}"     # the export wrapper's own idle gate
GPU_WAIT_SECONDS="${GPU_WAIT_SECONDS:-600}" # deadline for the GPUs to go idle
POLL_SECONDS="${POLL_SECONDS:-5}"
IDLE_CHECKS="${IDLE_CHECKS:-3}"             # consecutive idle polls before proceeding
# A package is at most about its checkpoint's size (v16: 166 GiB checkpoint, 168 GiB
# package). Its blobs are content-addressed, so it can dedupe against an existing
# package (cyber-hybrid-bf16, mostly v16's bytes, added 37 GiB; cyber-hybrid, whose
# splice touches every layer, added 168), but that is not knowable before the export,
# so preflight budgets the worst case: the checkpoint's size plus this margin.
DISK_MARGIN_PERCENT="${DISK_MARGIN_PERCENT:-10}"

status() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATUS_FILE"; }

# --- pure ----------------------------------------------------------------------------

# export_fits CHECKPOINT_BYTES AVAIL_BYTES MARGIN_PERCENT: true when a
# checkpoint-sized package plus the margin fits in the free space.
export_fits() {
  (( $2 >= $1 + $1 * $3 / 100 ))
}

gib() { echo $(( $1 / 1024 / 1024 / 1024 )); }

# --- measurements (tests redefine these) ---------------------------------------------

checkpoint_bytes() { du -s --apparent-size -B1 "$1" | cut -f1; }
avail_bytes() { df --output=avail -B1 "$1" | tail -1 | tr -d ' '; }

# preflight VARIANT: parse the variant into its checkpoint with the variant table
# the wrapper itself will source, then check the checkpoint and the disk. Prints
# what it established, or why it refused (status 1). Stops nothing.
preflight() {
  local model ckpt need avail
  [ -r "$EXPORT_WRAPPER" ] || { echo "export wrapper $EXPORT_WRAPPER is missing"; return 1; }
  [ -r "$VARIANTS_LIB" ] || {
    echo "variant table $VARIANTS_LIB is missing (launch from a whole snapshot with launch-glm53-export.sh, never a lone copy)"
    return 1
  }
  # shellcheck source=scripts/inference/glm53/hyperflare-variants.sh
  model="$(source "$VARIANTS_LIB" && hyperflare_resolve_model "$1" 2>/dev/null)" \
    || { echo "unknown variant '$1' in $VARIANTS_LIB"; return 1; }
  ckpt="$ROOT_HOST/$model"
  [ -r "$ckpt/config.json" ] || { echo "no checkpoint at $ckpt"; return 1; }
  need="$(checkpoint_bytes "$ckpt")" || { echo "could not measure $ckpt"; return 1; }
  avail="$(avail_bytes "$ROOT_HOST")" || { echo "could not measure the free space under $ROOT_HOST"; return 1; }
  export_fits "$need" "$avail" "$DISK_MARGIN_PERCENT" || {
    echo "disk: the package needs ~$(gib "$need") GiB + ${DISK_MARGIN_PERCENT}%, $ROOT_HOST has $(gib "$avail") GiB free"
    return 1
  }
  echo "$ckpt ($(gib "$need") GiB), $(gib "$avail") GiB free"
}

# --- effects -------------------------------------------------------------------------

# The serving primaries stop_primaries stopped (a leftover export container is
# stopped but never restarted), for restore_primaries.
STOPPED=()

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
    [[ "$name" == *-export ]] || STOPPED+=("$name")
  done
}

# Start every primary stop_primaries stopped. Status 1 when any did not start;
# each outcome is recorded.
restore_primaries() {
  local name rc=0
  for name in ${STOPPED[@]+"${STOPPED[@]}"}; do
    if "$DOCKER" start "$name" >/dev/null; then
      status "restarted $name"
    else
      status "failed to restart $name"
      rc=1
    fi
  done
  return "$rc"
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
  local variant="${1:-}" checked
  if [ -z "$variant" ]; then
    echo "usage: ${0##*/} VARIANT" >&2
    return 2
  fi
  VARIANT="$variant"
  STATUS_FILE="${STATUS_FILE:-/tmp/glm-export-$VARIANT.status}"
  LOG="${LOG:-/tmp/glm-export-$VARIANT.log}"
  EXPORT_WRAPPER="${EXPORT_WRAPPER:-$SCRIPT_DIR/export-glm53-flash-hyperflare-tp2-v16.sh}"
  # The table the wrapper sources is the one beside the wrapper.
  VARIANTS_LIB="${VARIANTS_LIB:-$(dirname "$EXPORT_WRAPPER")/hyperflare-variants.sh}"
  : > "$STATUS_FILE"
  status "driver start (variant $VARIANT, from $SCRIPT_DIR)"

  checked="$(preflight "$VARIANT")" || {
    status "aborted before stopping anything: $checked"
    return 1
  }
  status "preflight ok: $checked"

  local restored=0
  if ! stop_primaries; then
    restore_primaries || true
    status "aborted: a primary would not stop; nothing was exported"
    return 1
  fi
  status "waiting for idle GPUs"
  if ! await_idle_gpus; then
    restore_primaries || true
    status "aborted: GPUs never went idle; nothing was exported"
    return 1
  fi

  status "export starting (log $LOG)"
  local rc=0
  # Through bash: the wrapper's exec bit is not part of the contract.
  VARIANT="$VARIANT" ROOT_HOST="$ROOT_HOST" bash "$EXPORT_WRAPPER" >>"$LOG" 2>&1 || rc=$?
  restore_primaries || restored=$?
  if (( rc == 0 )); then
    status "done $(sed -n 's/^PACKAGE OK: //p' "$LOG" | tail -1)"
    return "$restored"
  fi
  status "failed exit=$rc (see $LOG)"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
