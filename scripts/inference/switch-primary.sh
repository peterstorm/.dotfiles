#!/usr/bin/env bash
# Switch desktop's primary model. The primaries are three served models on two
# engines, one engine on both GPUs at a time:
#   glm       glm-5.3-flash-hyperflare-tp2-v16  NVIDIA Hyperflare  (glm53/switch-glm53-hyperflare-tp2-v16.sh)
#   warmind   warmind-1017-native               ds4-native + Maya  (deepseek/ds41-1017-native/run-ds41-1017-native.sh)
#   deepseek  deepseek-v4.1-flash-native        ds4-native + Maya  (same launcher, WEIGHTS=deepseek)
#
# Usage: switch-primary.sh [toggle|glm|warmind|deepseek|status]   (default: toggle)
#   toggle    GLM -> GLM_TOGGLE_TARGET (WARMIND), WARMIND or DeepSeek -> GLM; with
#             nothing running, bring back whichever primary stopped last
#   glm|warmind|deepseek
#             make that one the primary (no-op if it already is)
#   status    what serves now, and what toggle would do
#
# Run anywhere: off desktop it re-runs itself there over ssh. Each engine keeps
# its own launcher, gates, acceptance and rollback; this script only decides
# (primary_decide, pure, tests/switch-primary-unit.sh) and sequences them. A
# cutover first requires :8000 to be idle, and a failed start brings the previous
# primary back. Both engines answer any model id, so a pi session pinned to one
# id keeps working after a switch with that entry's limits; the script prints
# the id that matches what now serves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLM_CONTAINER="glm53-flash-hyperflare-tp2-v16"
DS41_CONTAINER="ds41-1017-native"
GLM_SWITCH="$SCRIPT_DIR/glm53/switch-glm53-hyperflare-tp2-v16.sh"
DS41_RUN="$SCRIPT_DIR/deepseek/ds41-1017-native/run-ds41-1017-native.sh"
SERVING_HOST="desktop"
# The ds41 primary toggle starts from GLM. Fixed rather than taken from whichever
# weights ran last, so toggle is predictable (operator choice, 2026-11-14). Set it to
# deepseek to toggle to stock DeepSeek-V4.1 instead; `switch-primary.sh deepseek`
# reaches it either way.
GLM_TOGGLE_TARGET="warmind"

# --- functional core -------------------------------------------------------

# served model id -> primary name, and back. Unknown ids map to nothing.
primary_of_served() {
  case "$1" in
    glm-5.3-flash-hyperflare-tp2-v16) echo glm ;;
    warmind-1017-native) echo warmind ;;
    deepseek-v4.1-flash-native) echo deepseek ;;
    *) echo "" ;;
  esac
}
served_of_primary() {
  case "$1" in
    glm) echo glm-5.3-flash-hyperflare-tp2-v16 ;;
    warmind) echo warmind-1017-native ;;
    deepseek) echo deepseek-v4.1-flash-native ;;
  esac
}

# primary_decide REQUEST ACTIVE LAST GLM_PARTNER -> exactly one line:
#   start:<glm|warmind|deepseek> | noop:<primary> | error:<reason>
#   REQUEST    toggle | glm | warmind | deepseek
#   ACTIVE     glm | warmind | deepseek | none | both | other:<container>
#   LAST       glm | warmind | deepseek | none   (the primary that stopped most recently)
#   GLM_PARTNER warmind | deepseek              (the ds41 primary toggle starts from GLM)
# Total over its inputs: every combination yields one of the three forms.
primary_decide() {
  local request="$1" active="$2" last="$3" glm_partner="$4"
  case "$glm_partner" in warmind | deepseek) ;; *) glm_partner=warmind ;; esac
  case "$active" in
    both) echo "error:both primary engines are running; stop one by hand"; return ;;
    other:*) echo "error:${active#other:} holds the GPUs; stop it before switching primaries"; return ;;
    glm | warmind | deepseek | none) ;;
    *) echo "error:unknown active state '$active'"; return ;;
  esac
  case "$request" in
    toggle)
      case "$active" in
        glm) echo "start:$glm_partner" ;;
        warmind | deepseek) echo "start:glm" ;;
        none)
          case "$last" in
            glm | warmind | deepseek) echo "start:$last" ;;
            *) echo "error:nothing serves and no primary has run yet; name one: glm, warmind or deepseek" ;;
          esac
          ;;
      esac
      ;;
    glm | warmind | deepseek)
      if [ "$active" = "$request" ]; then echo "noop:$request"; else echo "start:$request"; fi
      ;;
    *) echo "error:unknown request '$request' (toggle, glm, warmind, deepseek or status)" ;;
  esac
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
  local glm=0 ds41=0 container status
  inference_container_running "$GLM_CONTAINER" || glm=$?
  inference_container_running "$DS41_CONTAINER" || ds41=$?
  # 0 running, 1 stopped/absent, anything else an inspection failure: fail closed.
  [ "$glm" -le 1 ] && [ "$ds41" -le 1 ] || die "cannot inspect the primary containers"
  if [ "$glm" = 0 ] && [ "$ds41" = 0 ]; then echo both; return; fi
  if [ "$glm" = 0 ]; then echo glm; return; fi
  if [ "$ds41" = 0 ]; then
    local served
    served="$(ds41_served_primary)"
    echo "${served:-other:$DS41_CONTAINER (unrecognised served model)}"
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

# The primary the ds41 container serves (or last served), from the label its
# launcher sets; empty when the label is missing or unrecognised.
ds41_served_primary() {
  primary_of_served "$(container_label "$DS41_CONTAINER" ai.peterstorm.inference.served-model)"
}

# LAST: of the two containers that exist, the one that stopped most recently
# (RFC 3339 UTC timestamps sort lexically); a ds41 stop counts as the weights it
# last served, WARMIND when its label is missing.
read_last() {
  local glm_at ds41_at ds41_primary
  glm_at="$(finished_at "$GLM_CONTAINER")"
  ds41_at="$(finished_at "$DS41_CONTAINER")"
  if [[ "$glm_at" == 0001-* && "$ds41_at" == 0001-* ]]; then echo none
  elif [[ "$glm_at" > "$ds41_at" ]]; then echo glm
  else ds41_primary="$(ds41_served_primary)"; echo "${ds41_primary:-warmind}"
  fi
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
    glm) "$GLM_SWITCH" stop ;;
    warmind | deepseek) "$DS41_RUN" --stop ;;
    none) ;;
  esac
}

start_primary() {
  case "$1" in
    # The GLM switcher quiesces whatever serves (idle-gated) and restores it if
    # GLM's acceptance fails.
    glm) "$GLM_SWITCH" start ;;
    warmind | deepseek) WEIGHTS="$1" "$DS41_RUN" --launch ;;
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
  if [ "$target" = glm ]; then
    # The GLM switcher gates, quiesces, accepts and rolls back by itself.
    start_primary glm || return 1
    report glm || return 1
    return 0
  fi
  # To ds41: gate on idle, stop what serves, launch, and on failure bring the
  # previous primary back with its own launcher.
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
    case "$active" in glm | warmind | deepseek) suffix=" ($(served_of_primary "$active"))" ;; esac
    echo "active:     $active$suffix"
    echo "last:       $last"
    echo "toggle ->   $(primary_decide toggle "$active" "$last" "$GLM_TOGGLE_TARGET")"
    return 0
  fi

  decision="$(primary_decide "$request" "$active" "$last" "$GLM_TOGGLE_TARGET")"
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
    local tty=()
    [ -t 0 ] && tty=(-t)
    exec ssh "${tty[@]}" "$SERVING_HOST" "\$HOME/.dotfiles/scripts/inference/switch-primary.sh $(printf '%q ' "$@")"
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
