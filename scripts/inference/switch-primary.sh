#!/usr/bin/env bash
# Switch desktop's primary model. The primaries are seven served models on three
# engines, one engine on both GPUs at a time:
#   glm                glm-5.3-flash-hyperflare-tp2-v16         NVIDIA Hyperflare  (glm53/switch-glm53-hyperflare-tp2-v16.sh, VARIANT=v16)
#   uncensored         glm-5.3-flash-hyperflare-tp2-uncensored  NVIDIA Hyperflare  (same switcher, VARIANT=uncensored: dealignai's UNCENSORED build in v16's storage)
#   warmind            warmind-1017-native                      ds4-native + Maya  (deepseek/ds41-1017-native/run-ds41-1017-native.sh)
#   deepseek           deepseek-v4.1-flash-native               ds4-native + Maya  (same launcher, WEIGHTS=deepseek)
#   glm-native         glm-5.3-native                           ds4-native GLM-5.3 full + Maya  (glm53/glm53-native/run-glm53-native.sh, WEIGHTS=stock: zai's release)
#   uncensored-native  glm-5.3-uncensored-native                same launcher, WEIGHTS=uncensored (kitaniai's: dealignai's UNCENSORED surgery)
#   cyber-native       glm-5.3-cyber-native                     same launcher, WEIGHTS=cyber (dealignai's CYBERSECURITY surgery)
#
# Usage: switch-primary.sh [toggle|PRIMARY|status]   (default: toggle)
#   toggle    stock <-> uncensored on the engine that serves: GLM <-> uncensored (Hyperflare),
#             DeepSeek <-> WARMIND (ds4-native), glm-native <-> uncensored-native (GLM-5.3 full);
#             with nothing running, bring back whichever primary stopped last. cyber-native has
#             no counterpart: toggling it is refused
#   PRIMARY   glm, uncensored, warmind, deepseek, glm-native, uncensored-native or cyber-native:
#             make that one the primary (no-op if it already is)
#   status    what serves now, and what toggle would do
#
# Run anywhere: off desktop it re-runs itself there over ssh. Each engine keeps
# its own launcher, gates, acceptance and rollback; this script only decides
# (primary_decide, pure, tests/switch-primary-unit.sh) and sequences them. A
# cutover first requires :8000 to be idle, and a failed start brings the previous
# primary back. Every engine answers any model id, so a pi session pinned to one
# id keeps working after a switch with that entry's limits; the script prints
# the id that matches what now serves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLM_CONTAINER="glm53-flash-hyperflare-tp2-v16"
UNCENSORED_CONTAINER="glm53-flash-hyperflare-tp2-uncensored"
DS41_CONTAINER="ds41-1017-native"
GLM_NATIVE_CONTAINER="glm53-native"
# Every container that can be a primary; the catalog's other profiles are foreign to the switcher.
PRIMARY_CONTAINERS=("$GLM_CONTAINER" "$UNCENSORED_CONTAINER" "$DS41_CONTAINER" "$GLM_NATIVE_CONTAINER")
# The Hyperflare primaries share one switcher; it serves the variant it is given.
GLM_SWITCH="$SCRIPT_DIR/glm53/switch-glm53-hyperflare-tp2-v16.sh"
DS41_RUN="$SCRIPT_DIR/deepseek/ds41-1017-native/run-ds41-1017-native.sh"
GLM_NATIVE_RUN="$SCRIPT_DIR/glm53/glm53-native/run-glm53-native.sh"
SERVING_HOST="desktop"

# --- functional core -------------------------------------------------------

# served model id -> primary name, and back. Unknown ids map to nothing.
primary_of_served() {
  case "$1" in
    glm-5.3-flash-hyperflare-tp2-v16) echo glm ;;
    glm-5.3-flash-hyperflare-tp2-uncensored) echo uncensored ;;
    warmind-1017-native) echo warmind ;;
    deepseek-v4.1-flash-native) echo deepseek ;;
    glm-5.3-native) echo glm-native ;;
    glm-5.3-uncensored-native) echo uncensored-native ;;
    glm-5.3-cyber-native) echo cyber-native ;;
    *) echo "" ;;
  esac
}
served_of_primary() {
  case "$1" in
    glm) echo glm-5.3-flash-hyperflare-tp2-v16 ;;
    uncensored) echo glm-5.3-flash-hyperflare-tp2-uncensored ;;
    warmind) echo warmind-1017-native ;;
    deepseek) echo deepseek-v4.1-flash-native ;;
    glm-native) echo glm-5.3-native ;;
    uncensored-native) echo glm-5.3-uncensored-native ;;
    cyber-native) echo glm-5.3-cyber-native ;;
  esac
}

# Whether a name is a primary: the one list every decision below checks against.
PRIMARY_NAMES="glm, uncensored, warmind, deepseek, glm-native, uncensored-native or cyber-native"
is_primary() {
  case "$1" in
    glm | uncensored | warmind | deepseek | glm-native | uncensored-native | cyber-native) return 0 ;;
    *) return 1 ;;
  esac
}

# The Hyperflare variant a Hyperflare primary serves (hyperflare-variants.sh names it); empty for ds4-native's.
variant_of_primary() {
  case "$1" in
    glm) echo v16 ;;
    uncensored) echo uncensored ;;
  esac
}

# The Backbone a GLM-5.3 full primary serves (run-glm53-native.sh's WEIGHTS); empty for the others.
weights_of_primary() {
  case "$1" in
    glm-native) echo stock ;;
    uncensored-native) echo uncensored ;;
    cyber-native) echo cyber ;;
  esac
}

# A primary's counterpart: the same model on the same engine, stock <-> uncensored (dealignai's
# GLM builds, jcartu's WARMIND). Toggle's whole graph (operator choice, 2026-11-19); empty for
# anything that is not a primary, and for cyber-native (a security tuning, reached by name).
counterpart_of() {
  case "$1" in
    glm) echo uncensored ;;
    uncensored) echo glm ;;
    deepseek) echo warmind ;;
    warmind) echo deepseek ;;
    glm-native) echo uncensored-native ;;
    uncensored-native) echo glm-native ;;
  esac
}

# primary_decide REQUEST ACTIVE LAST -> exactly one line:
#   start:<primary> | noop:<primary> | error:<reason>
#   REQUEST    toggle | <primary>
#   ACTIVE     <primary> | none | multiple | other:<container>
#   LAST       <primary> | none   (the primary that stopped most recently)
# Toggle goes to the active primary's counterpart, so it stays on the engine that serves and two
# toggles return to where they began; a primary without one (cyber-native) refuses it; with nothing
# active it brings back LAST. Total over its inputs: every combination yields one of the three forms.
primary_decide() {
  local request="$1" active="$2" last="$3" counterpart
  case "$active" in
    multiple) echo "error:more than one primary is running; stop all but one by hand"; return ;;
    other:*) echo "error:${active#other:} holds the GPUs; stop it before switching primaries"; return ;;
    none) ;;
    *) is_primary "$active" || { echo "error:unknown active state '$active'"; return; } ;;
  esac
  if [ "$request" = toggle ]; then
    if [ "$active" = none ]; then
      if is_primary "$last"; then
        echo "start:$last"
      else
        echo "error:nothing serves and no primary has run yet; name one: $PRIMARY_NAMES"
      fi
      return
    fi
    counterpart="$(counterpart_of "$active")"
    if [ -n "$counterpart" ]; then
      echo "start:$counterpart"
    else
      echo "error:$active has no stock/uncensored counterpart to toggle to; name a primary: $PRIMARY_NAMES"
    fi
  elif is_primary "$request"; then
    if [ "$active" = "$request" ]; then echo "noop:$request"; else echo "start:$request"; fi
  else
    echo "error:unknown request '$request' (toggle, $PRIMARY_NAMES, or status)"
  fi
}

# --- imperative shell ------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }

container_label() {
  docker inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null || true
}

finished_at() {
  docker inspect --format '{{.State.FinishedAt}}' "$1" 2>/dev/null || echo "0001-01-01T00:00:00Z"
}

# ACTIVE, from the containers themselves.
read_active() {
  local container status primary live=()
  for container in "${PRIMARY_CONTAINERS[@]}"; do
    status=0
    inference_container_running "$container" || status=$?
    # 0 running, 1 stopped/absent, anything else an inspection failure: fail closed.
    case "$status" in
      0) live+=("$container") ;;
      1) ;;
      *) die "cannot inspect the primary containers" ;;
    esac
  done
  if [ "${#live[@]}" -gt 1 ]; then echo multiple; return; fi
  if [ "${#live[@]}" -eq 1 ]; then
    primary="$(primary_of_container "${live[0]}")"
    echo "${primary:-other:${live[0]} (unrecognised served model)}"
    return
  fi
  for container in "${INFERENCE_PROFILE_CONTAINERS[@]}"; do
    status=0
    inference_container_running "$container" || status=$?
    [ "$status" = 0 ] && { echo "other:$container"; return; }
    [ "$status" = 1 ] || die "cannot inspect $container"
  done
  echo none
}

# The primary a container serves (or last served), from the served-model label
# its launcher sets; empty when the label is missing or names no primary.
labelled_primary() {
  primary_of_served "$(container_label "$1" ai.peterstorm.inference.served-model)"
}

# The primary a primary container serves: fixed for a Hyperflare container, and
# for a ds4-native one the weights its launcher labelled it with (empty when the
# label is missing or names no primary).
primary_of_container() {
  case "$1" in
    "$GLM_CONTAINER") echo glm ;;
    "$UNCENSORED_CONTAINER") echo uncensored ;;
    "$DS41_CONTAINER" | "$GLM_NATIVE_CONTAINER") labelled_primary "$1" ;;
  esac
}

# LAST: of the primary containers that exist, the one that stopped most recently
# (RFC 3339 UTC timestamps sort lexically); a ds4-native stop counts as the
# weights it last served, its launcher's default (WARMIND, GLM-5.3 uncensored)
# when the label is missing or names no primary.
read_last() {
  local container stopped_at primary newest="" newest_at="0001-01-01T00:00:00Z"
  for container in "${PRIMARY_CONTAINERS[@]}"; do
    stopped_at="$(finished_at "$container")"
    if [[ "$stopped_at" > "$newest_at" ]]; then newest="$container"; newest_at="$stopped_at"; fi
  done
  [ -n "$newest" ] || { echo none; return; }
  primary="$(primary_of_container "$newest")"
  if [ -z "$primary" ]; then
    case "$newest" in "$GLM_NATIVE_CONTAINER") primary=uncensored-native ;; *) primary=warmind ;; esac
  fi
  echo "$primary"
}

# Returns 1 (does not exit) so the rollback path can still run after a timeout.
# Only a numeric reading can prove the GPUs free: a failed or empty nvidia-smi
# keeps polling (callers run this with errexit suppressed, where an empty value
# would otherwise compare as 0 MiB).
GPU_FREE_TIMEOUT_SECONDS="${GPU_FREE_TIMEOUT_SECONDS:-90}"
GPU_POLL_SECONDS="${GPU_POLL_SECONDS:-3}"
wait_for_free_gpus() {
  local deadline=$((SECONDS + GPU_FREE_TIMEOUT_SECONDS)) used last="no reading"
  while ((SECONDS < deadline)); do
    used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -1 | tr -d ' ')" || used=""
    if [[ "$used" =~ ^[0-9]+$ ]]; then
      ((used <= 1024)) && return 0
      last="${used} MiB in use"
    else
      last="nvidia-smi gave no reading"
    fi
    sleep "$GPU_POLL_SECONDS"
  done
  echo "error: GPUs not free within ${GPU_FREE_TIMEOUT_SECONDS} s after stopping the previous primary (${last})" >&2
  return 1
}

stop_primary() {
  case "$1" in
    glm | uncensored) VARIANT="$(variant_of_primary "$1")" "$GLM_SWITCH" stop ;;
    warmind | deepseek) "$DS41_RUN" --stop ;;
    glm-native | uncensored-native | cyber-native) "$GLM_NATIVE_RUN" --stop ;;
    none) ;;
  esac
}

start_primary() {
  case "$1" in
    # The Hyperflare switcher quiesces whatever serves (idle-gated) and restores it if
    # the variant's acceptance fails. VARIANT is always explicit, so one inherited from
    # the caller's environment cannot pick the wrong profile.
    glm | uncensored) VARIANT="$(variant_of_primary "$1")" "$GLM_SWITCH" start ;;
    warmind | deepseek) WEIGHTS="$1" "$DS41_RUN" --launch ;;
    # WEIGHTS explicit, as VARIANT above: an inherited WEIGHTS cannot pick the Backbone.
    glm-native | uncensored-native | cyber-native) WEIGHTS="$(weights_of_primary "$1")" "$GLM_NATIVE_RUN" --launch ;;
  esac
}

# report PRIMARY [noop]: the one report format callers parse (pi's /switch reads
# the PRIMARY line, and the no-op line when nothing had to change).
report() {
  local primary="$1" served
  served="$(served_of_primary "$primary")"
  [ -n "$served" ] || { echo "error: no served id for primary '$primary'" >&2; return 1; }
  echo "PRIMARY: $primary ($served on :8000)"
  echo "pi:      pi --model desktop-vllm/$served"
  if [ "${2:-}" = noop ]; then echo "(already the primary; nothing to do)"; fi
}

# Returns non-zero on failure (main exits), so the sequencing is testable with
# stubbed effects (tests/switch-primary-unit.sh).
switch_to() {
  local target="$1" active="$2"
  case "$target" in
    glm | uncensored)
      # The Hyperflare switcher gates, quiesces, accepts and rolls back by itself.
      start_primary "$target" || return 1
      report "$target" || return 1
      return 0
      ;;
  esac
  # To a ds4-native primary: gate on idle, stop what serves, launch, and on
  # failure bring the previous primary back with its own launcher.
  if [ "$active" != none ]; then
    inference_require_idle_endpoint || return 1
  fi
  stop_primary "$active" || { echo "error: could not stop $active; nothing was started" >&2; return 1; }
  if ! wait_for_free_gpus || ! start_primary "$target"; then
    echo "error: $target failed to start; restoring $active" >&2
    if [ "$active" != none ]; then
      wait_for_free_gpus || true
      start_primary "$active" || echo "error: rollback to $active failed too; nothing serves" >&2
    fi
    return 1
  fi
  report "$target"
}

# run_request REQUEST: read the containers, decide, act. Returns non-zero on
# failure; split from main (host re-exec and sourcing) so tests can drive it
# with stubbed state (tests/switch-primary-unit.sh).
run_request() {
  local request="$1" active last decision
  active="$(read_active)" || return 1
  last="$(read_last)" || return 1
  if [ "$request" = status ]; then
    local suffix=""
    if is_primary "$active"; then suffix=" ($(served_of_primary "$active"))"; fi
    echo "active:     $active$suffix"
    echo "last:       $last"
    echo "toggle ->   $(primary_decide toggle "$active" "$last")"
    return 0
  fi

  decision="$(primary_decide "$request" "$active" "$last")"
  case "$decision" in
    noop:*) report "${decision#noop:}" noop ;;
    start:*) echo "switching: $active -> ${decision#start:}"; switch_to "${decision#start:}" "$active" ;;
    error:*) echo "error: ${decision#error:}" >&2; return 1 ;;
    *) echo "error: internal: unexpected decision '$decision'" >&2; return 1 ;;
  esac
}

main() {
  local request="${1:-toggle}"
  if [ "$(hostname)" != "$SERVING_HOST" ]; then
    # A scalar flag, not an array: macOS bash 3.2 treats "${empty[@]}" as an
    # unbound variable under `set -u`, which broke /switch whenever stdin was
    # not a terminal. ${force_tty:+-t} expands to zero or one word on any bash.
    local force_tty=""
    [ -t 0 ] && force_tty=1
    # shellcheck disable=SC2086 # intentional: the flag is either empty or -t
    exec ssh ${force_tty:+-t} "$SERVING_HOST" "\$HOME/.dotfiles/scripts/inference/switch-primary.sh $(printf '%q ' "$@")"
  fi
  # shellcheck source=scripts/inference/shared/inference-api-key.sh
  source "$SCRIPT_DIR/shared/inference-api-key.sh"
  # shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
  source "$SCRIPT_DIR/shared/inference-profile-catalog.sh"
  run_request "$request" || exit 1
}

# Run only when executed, never when sourced: `return` succeeds only in a sourced
# file, whatever $0 is (`bash -c 'source script' script` sets $0 to the script).
if ! (return 0 2>/dev/null); then
  main "$@"
fi
