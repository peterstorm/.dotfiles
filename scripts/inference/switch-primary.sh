#!/usr/bin/env bash
# Switch desktop's primary model. The primaries are three served models on two
# engines, one engine on both GPUs at a time:
#   glm       glm-5.3-flash-hyperflare-tp2-v16  NVIDIA Hyperflare  (glm53/switch-glm53-hyperflare-tp2-v16.sh)
#   warmind   warmind-1017-native               ds4-native + Maya  (deepseek/ds41-1017-native/run-ds41-1017-native.sh)
#   deepseek  deepseek-v4.1-flash-native        ds4-native + Maya  (same launcher, WEIGHTS=deepseek)
#
# Usage: switch-primary.sh [toggle|glm|warmind|deepseek|status]   (default: toggle)
#   toggle    GLM <-> the ds41 model that last ran (WARMIND if none has); with
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

# primary_decide REQUEST ACTIVE LAST LAST_DS41 -> exactly one line:
#   start:<glm|warmind|deepseek> | noop:<primary> | error:<reason>
#   REQUEST    toggle | glm | warmind | deepseek
#   ACTIVE     glm | warmind | deepseek | none | both | other:<container>
#   LAST       glm | warmind | deepseek | none   (the primary that stopped most recently)
#   LAST_DS41  warmind | deepseek                (weights the ds41 container last served)
# Total over its inputs: every combination yields one of the three forms.
primary_decide() {
  local request="$1" active="$2" last="$3" last_ds41="$4"
  case "$last_ds41" in warmind | deepseek) ;; *) last_ds41=warmind ;; esac
  case "$active" in
    both) echo "error:both primary engines are running; stop one by hand"; return ;;
    other:*) echo "error:${active#other:} holds the GPUs; stop it before switching primaries"; return ;;
    glm | warmind | deepseek | none) ;;
    *) echo "error:unknown active state '$active'"; return ;;
  esac
  case "$request" in
    toggle)
      case "$active" in
        glm) echo "start:$last_ds41" ;;
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
    primary_of_served "$(container_label "$DS41_CONTAINER" ai.peterstorm.inference.served-model)" | grep . \
      || echo "other:$DS41_CONTAINER (unrecognised served model)"
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

read_last_ds41() {
  local primary
  primary="$(primary_of_served "$(container_label "$DS41_CONTAINER" ai.peterstorm.inference.served-model)")"
  echo "${primary:-warmind}"
}

# LAST: of the two containers that exist, the one that stopped most recently
# (RFC 3339 UTC timestamps sort lexically).
read_last() {
  local glm_at ds41_at
  glm_at="$(finished_at "$GLM_CONTAINER")"
  ds41_at="$(finished_at "$DS41_CONTAINER")"
  if [[ "$glm_at" == 0001-* && "$ds41_at" == 0001-* ]]; then echo none
  elif [[ "$glm_at" > "$ds41_at" ]]; then echo glm
  else read_last_ds41
  fi
}

# Returns 1 (does not exit) so the rollback path can still run after a timeout.
wait_for_free_gpus() {
  local deadline=$((SECONDS + 90)) used
  while ((SECONDS < deadline)); do
    used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sort -n | tail -1 | tr -d ' ')"
    ((used <= 1024)) && return 0
    sleep 3
  done
  echo "error: GPU memory was not released within 90 s after stopping the previous primary" >&2
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

report() {
  local primary="$1" served
  served="$(served_of_primary "$primary")"
  echo "PRIMARY: $primary ($served on :8000)"
  echo "pi:      pi --model desktop-vllm/$served"
}

switch_to() {
  local target="$1" active="$2"
  if [ "$target" = glm ]; then
    start_primary glm
    report glm
    return
  fi
  # To ds41: gate on idle, stop what serves, launch, and on failure bring the
  # previous primary back with its own launcher.
  [ "$active" = none ] || inference_require_idle_endpoint
  stop_primary "$active"
  if ! wait_for_free_gpus || ! start_primary "$target"; then
    echo "error: $target failed to start; restoring $active" >&2
    if [ "$active" != none ]; then
      wait_for_free_gpus || true
      start_primary "$active" || echo "error: rollback to $active failed too; nothing serves" >&2
    fi
    exit 1
  fi
  report "$target"
}

main() {
  local request="${1:-toggle}" active last last_ds41 decision
  if [ "$(hostname)" != "$SERVING_HOST" ]; then
    local tty=()
    [ -t 0 ] && tty=(-t)
    exec ssh "${tty[@]}" "$SERVING_HOST" "\$HOME/.dotfiles/scripts/inference/switch-primary.sh $(printf '%q ' "$@")"
  fi
  # shellcheck source=scripts/inference/shared/inference-api-key.sh
  source "$SCRIPT_DIR/shared/inference-api-key.sh"
  # shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
  source "$SCRIPT_DIR/shared/inference-profile-catalog.sh"

  active="$(read_active)"
  last="$(read_last)"
  last_ds41="$(read_last_ds41)"
  if [ "$request" = status ]; then
    echo "active:     $active$([ "$active" = none ] || [[ "$active" == other:* ]] || [ "$active" = both ] || echo " ($(served_of_primary "$active"))")"
    echo "last:       $last"
    echo "toggle ->   $(primary_decide toggle "$active" "$last" "$last_ds41")"
    return 0
  fi

  decision="$(primary_decide "$request" "$active" "$last" "$last_ds41")"
  case "$decision" in
    noop:*) report "${decision#noop:}"; echo "(already the primary; nothing to do)" ;;
    start:*) echo "switching: $active -> ${decision#start:}"; switch_to "${decision#start:}" "$active" ;;
    error:*) die "${decision#error:}" ;;
    *) die "internal: unexpected decision '$decision'" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
