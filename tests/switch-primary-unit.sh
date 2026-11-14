#!/usr/bin/env bash
# Unit tests for switch-primary.sh's functional core (primary_decide and the
# served-id mapping). Pure: sources the script without running main, so no
# Docker, GPU or ssh. Exhaustive over the input space rather than examples:
# every (request, active, last, glm_partner) combination is checked against the
# properties the switcher relies on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/inference/switch-primary.sh
source "$ROOT/scripts/inference/switch-primary.sh"

failures=0
cases=0
check() {
  cases=$((cases + 1))
  if ! eval "$2"; then
    failures=$((failures + 1))
    echo "FAIL $1" >&2
  fi
}

PRIMARIES=(glm warmind deepseek)
REQUESTS=(toggle glm warmind deepseek bogus "")
ACTIVES=(glm warmind deepseek none both other:qwen38-27b-bf16 weird "")
LASTS=(glm warmind deepseek none "")
GLM_PARTNERS=(warmind deepseek "" junk)
engine() { case "$1" in glm) echo hyperflare ;; warmind | deepseek) echo ds4-native ;; *) echo none ;; esac; }

for request in "${REQUESTS[@]}"; do
  for active in "${ACTIVES[@]}"; do
    for last in "${LASTS[@]}"; do
      for glm_partner in "${GLM_PARTNERS[@]}"; do
        d="$(primary_decide "$request" "$active" "$last" "$glm_partner")"
        ctx="request='$request' active='$active' last='$last' glm_partner='$glm_partner' -> '$d'"
        # Totality: exactly one well-formed line.
        check "total: $ctx" '[[ "$d" =~ ^(start:(glm|warmind|deepseek)|noop:(glm|warmind|deepseek)|error:.+)$ ]]'
        # Never "start" what already serves.
        check "no self-start: $ctx" '[ "$d" != "start:$active" ]'
        # Two engines or a foreign profile on the GPUs is always refused.
        if [ "$active" = both ] || [[ "$active" == other:* ]]; then
          check "refuse foreign/both: $ctx" '[[ "$d" == error:* ]]'
        fi
        case "$active" in glm | warmind | deepseek | none) valid_active=1 ;; *) valid_active=0 ;; esac
        if [ "$valid_active" = 1 ]; then
          case "$request" in
            glm | warmind | deepseek)
              # An explicit request lands on exactly that primary.
              check "explicit: $ctx" '[ "$d" = "noop:$request" ] || [ "$d" = "start:$request" ]'
              check "noop iff already: $ctx" '[ "$active" != "$request" ] || [ "$d" = "noop:$request" ]'
              ;;
            toggle)
              if [ "$active" != none ]; then
                # Toggle always crosses to the other engine.
                check "toggle crosses engines: $ctx" \
                  '[[ "$d" == start:* ]] && [ "$(engine "${d#start:}")" != "$(engine "$active")" ]'
              fi
              if [ "$active" = glm ]; then
                expected="$glm_partner"; case "$expected" in warmind | deepseek) ;; *) expected=warmind ;; esac
                check "glm toggles to its partner: $ctx" '[ "$d" = "start:$expected" ]'
              fi
              if [ "$active" = none ]; then
                case "$last" in
                  glm | warmind | deepseek) check "resume last: $ctx" '[ "$d" = "start:$last" ]' ;;
                  *) check "nothing to resume: $ctx" '[[ "$d" == error:* ]]' ;;
                esac
              fi
              ;;
            *) check "unknown request refused: $ctx" '[[ "$d" == error:* ]]' ;;
          esac
        fi
      done
    done
  done
done

# Toggle is an involution across engines when the ds41 side is GLM's partner:
# two toggles return to the start.
for start in "${PRIMARIES[@]}"; do
  for glm_partner in warmind deepseek; do
    partner="$glm_partner"; [ "$start" = glm ] || partner="$start"
    first="$(primary_decide toggle "$start" none "$partner")"
    second="$(primary_decide toggle "${first#start:}" none "$partner")"
    check "toggle twice from $start returns ($first, $second)" '[ "$second" = "start:$start" ]'
  done
done

# Sourcing must never run main, whatever $0 is: on 2026-11-14 a test sourced the
# script as `bash -c 'source "$0"; …' SCRIPT`, the old BASH_SOURCE==$0 guard
# matched, and main ssh'd to desktop with a real switch request (the idle gate
# refused it). A stub ssh/hostname first on PATH records any call.
guard_bin="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "$0 $*" >>"%s/calls"\n' "$guard_bin" >"$guard_bin/ssh"
cp "$guard_bin/ssh" "$guard_bin/hostname"
chmod +x "$guard_bin/ssh" "$guard_bin/hostname"
PATH="$guard_bin:$PATH" bash -c 'source "$0" glm' "$ROOT/scripts/inference/switch-primary.sh" >/dev/null 2>&1 || true
PATH="$guard_bin:$PATH" bash -c 'source "$1" warmind' bash "$ROOT/scripts/inference/switch-primary.sh" >/dev/null 2>&1 || true
check "sourcing never runs main (no hostname or ssh call)" '[ ! -e "$guard_bin/calls" ]'
rm -rf "$guard_bin"

# GLM's toggle partner is the fixed GLM_TOGGLE_TARGET (run_request's tests below
# prove the shell passes it, not the ds41 container's last weights).
check "GLM toggle target is WARMIND" '[ "$GLM_TOGGLE_TARGET" = warmind ]'

# --- report: the exact lines pi's /switch parses -----------------------------
# pi/extensions/primary-switch/switch.test.ts runs this same function's output
# through parseSwitchReport; these pin the shell side.
for primary in "${PRIMARIES[@]}"; do
  served="$(served_of_primary "$primary")"
  check "report $primary" \
    '[ "$(report "$primary")" = "PRIMARY: $primary ($served on :8000)"$'"'"'\n'"'"'"pi:      pi --model desktop-vllm/$served" ]'
  check "report $primary noop" '[ "$(report "$primary" noop | tail -1)" = "(already the primary; nothing to do)" ]'
done
check "report refuses an unknown primary" '! report qwen >/dev/null 2>&1'

# The served-id mapping round-trips for every primary and rejects strangers.
for primary in "${PRIMARIES[@]}"; do
  check "round-trip $primary" '[ "$(primary_of_served "$(served_of_primary "$primary")")" = "$primary" ]'
done
check "unknown served id" '[ -z "$(primary_of_served qwen3.8-27b)" ]'

# --- wait_for_free_gpus: only a numeric reading proves the GPUs free ---------
GPU_FREE_TIMEOUT_SECONDS=1
GPU_POLL_SECONDS=0.1
gpu_reading=""
nvidia-smi() { [ -n "$gpu_reading" ] && printf '%s\n' "$gpu_reading"; return "${NVIDIA_RC:-0}"; }
gpu_wait() { ( wait_for_free_gpus 2>/dev/null ) && echo free || echo busy; }
gpu_reading=$'512\n300';            check "numeric idle reading frees" '[ "$(gpu_wait)" = free ]'
gpu_reading=$'512\n4096';           check "highest card decides" '[ "$(gpu_wait)" = busy ]'
gpu_reading="";                      check "empty reading is not free" '[ "$(gpu_wait)" = busy ]'
gpu_reading="[N/A]";                 check "non-numeric reading is not free" '[ "$(gpu_wait)" = busy ]'
gpu_reading=""; NVIDIA_RC=9;         check "failing nvidia-smi is not free" '[ "$(gpu_wait)" = busy ]'
unset NVIDIA_RC
unset -f nvidia-smi

# --- read_active / read_last against stubbed container state ----------------
INFERENCE_PROFILE_CONTAINERS=(qwen38-27b-bf16 "$GLM_CONTAINER" "$DS41_CONTAINER")
declare -A running=() label=() finished=()
inference_container_running() { [ "${running[$1]:-1}" = 0 ]; }
container_label() { printf '%s' "${label[$1]:-}"; }
finished_at() { printf '%s' "${finished[$1]:-0001-01-01T00:00:00Z}"; }
state() { running=(); label=(); finished=(); }

state; running[$GLM_CONTAINER]=0
check "active glm" '[ "$(read_active)" = glm ]'
state; running[$DS41_CONTAINER]=0; label[$DS41_CONTAINER]=deepseek-v4.1-flash-native
check "active ds41 serving stock DeepSeek" '[ "$(read_active)" = deepseek ]'
state; running[$DS41_CONTAINER]=0; label[$DS41_CONTAINER]=mystery
check "unrecognised ds41 label is foreign" '[[ "$(read_active)" == other:* ]]'
state; running[$GLM_CONTAINER]=0; running[$DS41_CONTAINER]=0
check "both engines up" '[ "$(read_active)" = both ]'
state; running[qwen38-27b-bf16]=0
check "foreign profile on the GPUs" '[ "$(read_active)" = "other:qwen38-27b-bf16" ]'
state
check "nothing running" '[ "$(read_active)" = none ]'
state; finished[$GLM_CONTAINER]=2026-11-14T10:00:00Z; finished[$DS41_CONTAINER]=2026-11-14T09:00:00Z
check "glm stopped last" '[ "$(read_last)" = glm ]'
state; finished[$GLM_CONTAINER]=2026-11-14T09:00:00Z; finished[$DS41_CONTAINER]=2026-11-14T10:00:00Z; label[$DS41_CONTAINER]=deepseek-v4.1-flash-native
check "ds41 stopped last, with its weights" '[ "$(read_last)" = deepseek ]'
state; finished[$DS41_CONTAINER]=2026-11-14T10:00:00Z
check "ds41 stopped last without a label defaults to warmind" '[ "$(read_last)" = warmind ]'
state
check "neither ever ran" '[ "$(read_last)" = none ]'

# --- switch_to sequencing with stubbed effects -------------------------------
# Each stub appends to a call log; FAIL_STARTS lists primaries whose start fails.
log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT
stop_primary() { echo "stop:$1" >>"$log_file"; return "${STOP_RC:-0}"; }
start_primary() { echo "start:$1" >>"$log_file"; [[ " ${FAIL_STARTS:-} " != *" $1 "* ]]; }
inference_require_idle_endpoint() { echo idle >>"$log_file"; return "${IDLE_RC:-0}"; }
wait_for_free_gpus() { echo gpus >>"$log_file"; return 0; }
report() { echo "report:$1" >>"$log_file"; }
# switch_out, switch_rc and calls are read by the check() eval strings below.
# shellcheck disable=SC2034
run_switch() {
  : >"$log_file"
  switch_rc=0
  switch_out="$( (switch_to "$1" "$2") 2>&1)" || switch_rc=$?
  calls="$(paste -sd' ' "$log_file")"
}

run_switch deepseek warmind
check "ds41 weights swap: gate, stop, wait, start, report" \
  '[ "$switch_rc" = 0 ] && [ "$calls" = "idle stop:warmind gpus start:deepseek report:deepseek" ]'
FAIL_STARTS="deepseek" run_switch deepseek glm
check "failed start restores the previous primary and fails" \
  '[ "$switch_rc" = 1 ] && [ "$calls" = "idle stop:glm gpus start:deepseek gpus start:glm" ]'
FAIL_STARTS="deepseek glm" run_switch deepseek glm
check "failed rollback says nothing serves" '[ "$switch_rc" = 1 ] && [[ "$switch_out" == *"nothing serves"* ]]'
IDLE_RC=1 run_switch warmind glm
check "busy endpoint stops nothing" '[ "$switch_rc" = 1 ] && [ "$calls" = idle ]'
STOP_RC=1 run_switch warmind glm
check "a failed stop starts nothing" '[ "$switch_rc" = 1 ] && [ "$calls" = "idle stop:glm" ]'
run_switch warmind none
check "from nothing: no idle gate, no rollback target" '[ "$switch_rc" = 0 ] && [ "$calls" = "stop:none gpus start:warmind report:warmind" ]'
run_switch glm warmind
check "to glm: its own switcher does gate and rollback" '[ "$switch_rc" = 0 ] && [ "$calls" = "start:glm report:glm" ]'
FAIL_STARTS="glm" run_switch glm warmind
check "failed glm switch fails without a report" '[ "$switch_rc" = 1 ] && [ "$calls" = "start:glm" ]'
REPORT_RC=1
report() { echo "report:$1" >>"$log_file"; return "${REPORT_RC:-0}"; }
run_switch glm warmind
check "a failed glm report fails the switch" '[ "$switch_rc" = 1 ] && [ "$calls" = "start:glm report:glm" ]'
unset REPORT_RC

# --- run_request: state in, decision, effects (stubbed above) ----------------
# request_out and request_rc are read by the check() eval strings below.
# shellcheck disable=SC2034
run() {
  : >"$log_file"
  request_rc=0
  request_out="$( (run_request "$1") 2>&1)" || request_rc=$?
  calls="$(paste -sd' ' "$log_file")"
}
# GLM serves; DeepSeek was the last weights the ds41 container ran.
state; running[$GLM_CONTAINER]=0; label[$DS41_CONTAINER]=deepseek-v4.1-flash-native
finished[$DS41_CONTAINER]=2026-11-14T10:00:00Z
run status
check "status names the served id and toggles GLM to WARMIND despite last DeepSeek" \
  '[ "$request_rc" = 0 ] && [ "$request_out" = "active:     glm (glm-5.3-flash-hyperflare-tp2-v16)"$'"'"'\n'"'"'"last:       deepseek"$'"'"'\n'"'"'"toggle ->   start:warmind" ] && [ -z "$calls" ]'
run toggle
check "toggle from GLM switches to WARMIND" \
  '[ "$request_rc" = 0 ] && [ "$calls" = "idle stop:glm gpus start:warmind report:warmind" ]'
run glm
check "already-serving request reports without switching" '[ "$request_rc" = 0 ] && [ "$calls" = "report:glm" ]'
state; running[$DS41_CONTAINER]=0; label[$DS41_CONTAINER]=warmind-1017-native
run toggle
check "toggle from WARMIND switches to GLM" '[ "$request_rc" = 0 ] && [ "$calls" = "start:glm report:glm" ]'
run status
check "status with nothing to suffix" '[[ "$request_out" == *"active:     warmind (warmind-1017-native)"* ]]'
state; running[qwen38-27b-bf16]=0
run toggle
check "a foreign profile refuses the switch and touches nothing" \
  '[ "$request_rc" = 1 ] && [ -z "$calls" ] && [[ "$request_out" == *"qwen38-27b-bf16 holds the GPUs"* ]]'
inference_container_running() { return 2; }
run status
check "an uninspectable container fails the request" '[ "$request_rc" = 1 ] && [ -z "$calls" ]'

if [ "$failures" -ne 0 ]; then
  echo "switch-primary unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "switch-primary unit: PASS ($cases checks)"
