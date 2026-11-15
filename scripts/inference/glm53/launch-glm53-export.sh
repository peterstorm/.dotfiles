#!/usr/bin/env bash
# Launch stop-and-export-glm53-hyperflare.sh on desktop from a committed
# snapshot of this directory, and report its preflight verdict.
#
# The driver runs the export wrapper and the variant table that sit beside it,
# so it must never run as a lone copied file: on 2026-11-15 a lone /tmp copy
# found a stale pre-variant wrapper there, stopped v16, and failed. This ships
# `git archive HEAD` of this directory to $REMOTE_BASE/glm53-export-<sha>/
# (immutable per commit; a re-launch at the same commit reuses it), starts the
# driver from there under setsid with stdin detached, then waits for the
# driver's preflight (variant, checkpoint, disk headroom — all checked before
# anything is stopped) and exits non-zero if it refused.
#
# Refuses before touching desktop when the variant is unknown or this directory
# has uncommitted changes (HEAD is what ships, so you would run code you are not
# looking at); refuses on desktop when an export driver is already running (each
# export needs both GPUs).
#
# Usage: launch-glm53-export.sh VARIANT
# Then:  ssh desktop cat /tmp/glm-export-VARIANT.status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/glm53/hyperflare-variants.sh
source "$SCRIPT_DIR/hyperflare-variants.sh"

HOST="${HOST:-desktop}"
SSH="${SSH:-ssh}"
REMOTE_BASE="${REMOTE_BASE:-/tmp}"
PREFLIGHT_WAIT_SECONDS="${PREFLIGHT_WAIT_SECONDS:-60}" # du over a 167 GiB checkpoint takes seconds
DRIVER=stop-and-export-glm53-hyperflare.sh

remote() { "$SSH" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$1"; }

main() {
  local variant="${1:-}" repo rel sha dir status_file rc=0
  if [ -z "$variant" ]; then
    echo "usage: ${0##*/} VARIANT (one of: ${HYPERFLARE_VARIANTS[*]})" >&2
    return 2
  fi
  # Parse first: after this, $variant is one of the table's fixed names, which is
  # what makes interpolating it into the remote commands below safe.
  hyperflare_resolve_model "$variant" >/dev/null || return 2

  repo="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
  rel="$(git -C "$SCRIPT_DIR" rev-parse --show-prefix)"
  rel="${rel%/}"
  if ! git -C "$repo" diff --quiet HEAD -- "$rel"; then
    echo "error: $rel has uncommitted changes; the launcher ships HEAD, so commit first" >&2
    return 1
  fi
  sha="$(git -C "$repo" rev-parse --short=12 HEAD)"
  dir="$REMOTE_BASE/glm53-export-$sha"
  status_file="$REMOTE_BASE/glm-export-$variant.status"

  # One export at a time. pgrep: 0 = found, 1 = none, anything else = no answer.
  remote "pgrep -af '[s]top-and-export-glm53-hyperflare\\.sh '" || rc=$?
  case "$rc" in
    0) echo "error: an export driver is already running on $HOST (above)" >&2; return 1 ;;
    1) ;;
    *) echo "error: could not ask $HOST for running drivers (exit $rc)" >&2; return 1 ;;
  esac

  git -C "$repo" archive --format=tar HEAD "$rel" | remote "set -eu
    d='$dir'
    if [ -d \"\$d\" ]; then cat >/dev/null; else
      t=\$(mktemp -d \"\$d.XXXXXX\"); tar -x -C \"\$t\"; mv -T \"\$t\" \"\$d\"
    fi"

  remote "rm -f '$status_file'
    cd / && STATUS_FILE='$status_file' LOG='$REMOTE_BASE/glm-export-$variant.log' \
      setsid nohup bash '$dir/$rel/$DRIVER' '$variant' \
      > '$REMOTE_BASE/glm-export-$variant.driver.log' 2>&1 < /dev/null &"
  echo "launched: $variant export on $HOST from $dir/$rel (commit $sha)"

  # The driver's own verdict: preflight ok (it goes on to stop and export) or aborted.
  local verdict
  verdict="$(remote "for _ in \$(seq $PREFLIGHT_WAIT_SECONDS); do
      grep -qE 'preflight ok|aborted' '$status_file' 2>/dev/null && break; sleep 1
    done; cat '$status_file' 2>/dev/null || true")"
  printf '%s\n' "$verdict"
  if grep -q 'aborted' <<<"$verdict"; then
    echo "error: the driver refused before stopping anything (above)" >&2
    return 1
  fi
  if ! grep -q 'preflight ok' <<<"$verdict"; then
    echo "error: no preflight verdict after ${PREFLIGHT_WAIT_SECONDS}s; see $HOST:$REMOTE_BASE/glm-export-$variant.driver.log" >&2
    return 1
  fi
  echo "poll:   ssh $HOST cat $status_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
