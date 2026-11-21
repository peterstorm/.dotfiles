#!/usr/bin/env bash
# Unit tests for switch-primary.sh's functional core (primary_decide and the
# served-id mapping). Pure: sources the script without running main, so no
# Docker, GPU or ssh. Exhaustive over the input space rather than examples:
# every (request, active, last) combination is checked against the properties
# the switcher relies on.
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

PRIMARIES=(glm uncensored warmind deepseek glm-native)
# The primaries toggle pairs up: each model's stock release and its uncensored build on one engine.
# GLM-5.3 full (glm-native) has no stock build here, so it has no counterpart.
PAIRED=(glm uncensored warmind deepseek)
REQUESTS=(toggle glm uncensored warmind deepseek glm-native bogus "")
ACTIVES=(glm uncensored warmind deepseek glm-native none multiple other:qwen38-27b-bf16 weird "")
LASTS=(glm uncensored warmind deepseek glm-native none "")
engine() { case "$1" in glm | uncensored) echo hyperflare ;; warmind | deepseek) echo ds4-native ;; glm-native) echo ds4-native-glm53 ;; *) echo none ;; esac; }
# Whether a primary is its model's stock release or its uncensored build (dealignai's GLM, WARMIND).
alignment() { case "$1" in glm | deepseek) echo stock ;; uncensored | warmind | glm-native) echo uncensored ;; *) echo none ;; esac; }

for request in "${REQUESTS[@]}"; do
  for active in "${ACTIVES[@]}"; do
    for last in "${LASTS[@]}"; do
      d="$(primary_decide "$request" "$active" "$last")"
      ctx="request='$request' active='$active' last='$last' -> '$d'"
      # Totality: exactly one well-formed line.
      check "total: $ctx" '[[ "$d" =~ ^(start:(glm|uncensored|warmind|deepseek|glm-native)|noop:(glm|uncensored|warmind|deepseek|glm-native)|error:.+)$ ]]'
      # Never "start" what already serves.
      check "no self-start: $ctx" '[ "$d" != "start:$active" ]'
      # More than one primary, or a foreign profile, on the GPUs is always refused.
      if [ "$active" = multiple ] || [[ "$active" == other:* ]]; then
        check "refuse foreign/multiple: $ctx" '[[ "$d" == error:* ]]'
      fi
      case "$active" in glm | uncensored | warmind | deepseek | glm-native | none) valid_active=1 ;; *) valid_active=0 ;; esac
      if [ "$valid_active" = 1 ]; then
        case "$request" in
          glm | uncensored | warmind | deepseek | glm-native)
            # An explicit request lands on exactly that primary.
            check "explicit: $ctx" '[ "$d" = "noop:$request" ] || [ "$d" = "start:$request" ]'
            check "noop iff already: $ctx" '[ "$active" != "$request" ] || [ "$d" = "noop:$request" ]'
            ;;
          toggle)
            if [ "$active" = glm-native ]; then
              # No counterpart: refused, naming the primaries to choose from.
              check "toggle refused without a counterpart: $ctx" '[[ "$d" == error:*"name a primary"* ]]'
            elif [ "$active" != none ]; then
              # Toggle stays on the engine that serves and flips stock <-> uncensored: the counterpart.
              check "toggle stays on its engine: $ctx" \
                '[[ "$d" == start:* ]] && [ "$(engine "${d#start:}")" = "$(engine "$active")" ]'
              check "toggle flips stock/uncensored: $ctx" '[ "$(alignment "${d#start:}")" != "$(alignment "$active")" ]'
              check "toggle ignores the last primary while one serves: $ctx" \
                '[ "$d" = "$(primary_decide toggle "$active" none)" ]'
            fi
            if [ "$active" = none ]; then
              case "$last" in
                glm | uncensored | warmind | deepseek | glm-native) check "resume last: $ctx" '[ "$d" = "start:$last" ]' ;;
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

# Toggle's pairs: each model's stock release and its uncensored build, on one engine.
check "toggle from GLM goes to uncensored" '[ "$(primary_decide toggle glm none)" = start:uncensored ]'
check "toggle from uncensored goes to GLM" '[ "$(primary_decide toggle uncensored none)" = start:glm ]'
check "toggle from DeepSeek goes to WARMIND" '[ "$(primary_decide toggle deepseek none)" = start:warmind ]'
check "toggle from WARMIND goes to DeepSeek" '[ "$(primary_decide toggle warmind none)" = start:deepseek ]'
# An involution: two toggles return to where they began.
for p in "${PAIRED[@]}"; do
  first="$(primary_decide toggle "$p" none)"
  second="$(primary_decide toggle "${first#start:}" none)"
  check "toggling twice from $p returns to it ($first, $second)" '[ "$second" = "start:$p" ]'
done
# The counterpart is defined for the paired primaries only.
for x in glm-native none multiple other:qwen38-27b-bf16 weird ""; do
  check "no counterpart for '$x'" '[ -z "$(counterpart_of "$x")" ]'
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
# The two Hyperflare primaries are told apart by served id alone.
check "glm serves the v16 id" '[ "$(served_of_primary glm)" = glm-5.3-flash-hyperflare-tp2-v16 ]'
check "uncensored serves its variant's id" '[ "$(served_of_primary uncensored)" = glm-5.3-flash-hyperflare-tp2-uncensored ]'
check "glm-native serves GLM-5.3 full's uncensored id" '[ "$(served_of_primary glm-native)" = glm-5.3-uncensored-native ]'
check "the cyber Backbone's id is no primary" '[ -z "$(primary_of_served glm-5.3-cyber-native)" ]'
check "the uncensored variant's id is uncensored" '[ "$(primary_of_served glm-5.3-flash-hyperflare-tp2-uncensored)" = uncensored ]'
check "each Hyperflare primary has its own variant" \
  '[ "$(variant_of_primary glm)" = v16 ] && [ "$(variant_of_primary uncensored)" = uncensored ] && [ -z "$(variant_of_primary warmind)" ]'
# Each Hyperflare primary's container is the one the variant table derives for its variant,
# and every primary is in the real profile catalog (the Hyperflare switcher quiesces only
# catalog profiles). The cyber-hybrid variants were retired on 2026-11-15: no longer a
# primary, a variant or a catalog profile.
check "Hyperflare primary containers derive from the variant table" \
  '( source "$ROOT/scripts/inference/glm53/hyperflare-variants.sh"
     [ "$(hyperflare_variant_container "$(variant_of_primary glm)")" = "$GLM_CONTAINER" ] &&
     [ "$(hyperflare_variant_container "$(variant_of_primary uncensored)")" = "$UNCENSORED_CONTAINER" ] )'
check "every primary is a catalog profile" \
  '( source "$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
     for c in "${PRIMARY_CONTAINERS[@]}"; do
       printf "%s\n" "${INFERENCE_PROFILE_CONTAINERS[@]}" | grep -Fxq "$c" || exit 1
     done )'
check "the retired cyber variants are neither primaries nor catalog profiles" \
  '( source "$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
     for c in glm53-flash-hyperflare-tp2-cyber-hybrid glm53-flash-hyperflare-tp2-cyber-hybrid-bf16; do
       printf "%s\n" "${PRIMARY_CONTAINERS[@]}" "${INFERENCE_PROFILE_CONTAINERS[@]}" | grep -Fxq "$c" && exit 1
     done; exit 0 )'

# --- dispatch: the real start/stop reach the right launcher with the right variant ---
# Stub launchers print what they were given; the stubs further down replace these functions.
dispatch_dir="$(mktemp -d)"
for stub in glm-switch ds41-run glm-native-run; do
  printf '#!/usr/bin/env bash\necho "%s VARIANT=${VARIANT-unset} WEIGHTS=${WEIGHTS-unset} $*"\n' "$stub" >"$dispatch_dir/$stub"
  chmod +x "$dispatch_dir/$stub"
done
GLM_SWITCH="$dispatch_dir/glm-switch"
DS41_RUN="$dispatch_dir/ds41-run"
GLM_NATIVE_RUN="$dispatch_dir/glm-native-run"
check "start glm serves variant v16" '[ "$(start_primary glm)" = "glm-switch VARIANT=v16 WEIGHTS=unset start" ]'
check "start uncensored serves variant uncensored" '[ "$(start_primary uncensored)" = "glm-switch VARIANT=uncensored WEIGHTS=unset start" ]'
check "stop glm stops v16" '[ "$(stop_primary glm)" = "glm-switch VARIANT=v16 WEIGHTS=unset stop" ]'
check "stop uncensored stops its variant" '[ "$(stop_primary uncensored)" = "glm-switch VARIANT=uncensored WEIGHTS=unset stop" ]'
check "an inherited VARIANT cannot pick the profile" \
  '[ "$(VARIANT=uncensored start_primary glm)" = "glm-switch VARIANT=v16 WEIGHTS=unset start" ]'
check "start warmind launches the ds41 weights" '[ "$(start_primary warmind)" = "ds41-run VARIANT=unset WEIGHTS=warmind --launch" ]'
check "start deepseek launches the ds41 weights" '[ "$(start_primary deepseek)" = "ds41-run VARIANT=unset WEIGHTS=deepseek --launch" ]'
check "stop warmind stops ds41" '[ "$(stop_primary warmind)" = "ds41-run VARIANT=unset WEIGHTS=unset --stop" ]'
check "stop none does nothing" '[ -z "$(stop_primary none)" ]'
check "start glm-native launches the uncensored Backbone" '[ "$(start_primary glm-native)" = "glm-native-run VARIANT=unset WEIGHTS=uncensored --launch" ]'
check "an inherited WEIGHTS cannot pick glm-native's Backbone" \
  '[ "$(WEIGHTS=cyber start_primary glm-native)" = "glm-native-run VARIANT=unset WEIGHTS=uncensored --launch" ]'
check "stop glm-native stops its container" '[ "$(stop_primary glm-native)" = "glm-native-run VARIANT=unset WEIGHTS=unset --stop" ]'
rm -rf "$dispatch_dir"

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
INFERENCE_PROFILE_CONTAINERS=(qwen38-27b-bf16 "$GLM_CONTAINER" "$UNCENSORED_CONTAINER" "$DS41_CONTAINER" "$GLM_NATIVE_CONTAINER")
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
state; running[$UNCENSORED_CONTAINER]=0
check "active uncensored" '[ "$(read_active)" = uncensored ]'
state; running[$GLM_CONTAINER]=0; running[$DS41_CONTAINER]=0
check "two engines up" '[ "$(read_active)" = multiple ]'
state; running[$GLM_CONTAINER]=0; running[$UNCENSORED_CONTAINER]=0
check "both Hyperflare variants up" '[ "$(read_active)" = multiple ]'
state; running[$UNCENSORED_CONTAINER]=0; running[$DS41_CONTAINER]=0
check "uncensored and ds41 up" '[ "$(read_active)" = multiple ]'
state; running[qwen38-27b-bf16]=0
check "foreign profile on the GPUs" '[ "$(read_active)" = "other:qwen38-27b-bf16" ]'
state; running[$GLM_NATIVE_CONTAINER]=0; label[$GLM_NATIVE_CONTAINER]=glm-5.3-uncensored-native
check "active glm-native" '[ "$(read_active)" = glm-native ]'
state; running[$GLM_NATIVE_CONTAINER]=0; label[$GLM_NATIVE_CONTAINER]=glm-5.3-cyber-native
check "the GLM container on its cyber Backbone is foreign" '[[ "$(read_active)" == other:"$GLM_NATIVE_CONTAINER"* ]]'
state; running[$GLM_NATIVE_CONTAINER]=0; running[$DS41_CONTAINER]=0; label[$GLM_NATIVE_CONTAINER]=glm-5.3-uncensored-native
check "glm-native and ds41 up" '[ "$(read_active)" = multiple ]'
state; finished[$DS41_CONTAINER]=2026-11-14T09:00:00Z; finished[$GLM_NATIVE_CONTAINER]=2026-11-14T10:00:00Z
check "glm-native stopped last without a label defaults to glm-native" '[ "$(read_last)" = glm-native ]'
state; finished[$GLM_NATIVE_CONTAINER]=2026-11-14T10:00:00Z; label[$GLM_NATIVE_CONTAINER]=glm-5.3-cyber-native
check "glm-native stopped last on its cyber Backbone resumes as glm-native" '[ "$(read_last)" = glm-native ]'
state
check "nothing running" '[ "$(read_active)" = none ]'
state; finished[$GLM_CONTAINER]=2026-11-14T10:00:00Z; finished[$DS41_CONTAINER]=2026-11-14T09:00:00Z
check "glm stopped last" '[ "$(read_last)" = glm ]'
state; finished[$GLM_CONTAINER]=2026-11-14T09:00:00Z; finished[$DS41_CONTAINER]=2026-11-14T10:00:00Z; label[$DS41_CONTAINER]=deepseek-v4.1-flash-native
check "ds41 stopped last, with its weights" '[ "$(read_last)" = deepseek ]'
state; finished[$DS41_CONTAINER]=2026-11-14T10:00:00Z
check "ds41 stopped last without a label defaults to warmind" '[ "$(read_last)" = warmind ]'
state; finished[$GLM_CONTAINER]=2026-11-14T10:00:00Z; finished[$UNCENSORED_CONTAINER]=2026-11-14T11:00:00Z; finished[$DS41_CONTAINER]=2026-11-14T09:00:00Z
check "uncensored stopped last" '[ "$(read_last)" = uncensored ]'
state; finished[$GLM_CONTAINER]=2026-11-14T12:00:00Z; finished[$UNCENSORED_CONTAINER]=2026-11-14T11:00:00Z
check "glm stopped after uncensored" '[ "$(read_last)" = glm ]'
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
run_switch uncensored warmind
check "to uncensored: its switcher does gate and rollback" '[ "$switch_rc" = 0 ] && [ "$calls" = "start:uncensored report:uncensored" ]'
run_switch uncensored glm
check "glm to uncensored stays inside the Hyperflare switcher" '[ "$switch_rc" = 0 ] && [ "$calls" = "start:uncensored report:uncensored" ]'
FAIL_STARTS="uncensored" run_switch uncensored warmind
check "failed uncensored switch fails without a report" '[ "$switch_rc" = 1 ] && [ "$calls" = "start:uncensored" ]'
run_switch warmind uncensored
check "from uncensored to warmind: gate, stop uncensored, wait, start, report" \
  '[ "$switch_rc" = 0 ] && [ "$calls" = "idle stop:uncensored gpus start:warmind report:warmind" ]'
FAIL_STARTS="warmind" run_switch warmind uncensored
check "a failed ds41 start restores uncensored" \
  '[ "$switch_rc" = 1 ] && [ "$calls" = "idle stop:uncensored gpus start:warmind gpus start:uncensored" ]'
run_switch glm-native warmind
check "to glm-native: gate, stop, wait, start, report" \
  '[ "$switch_rc" = 0 ] && [ "$calls" = "idle stop:warmind gpus start:glm-native report:glm-native" ]'
FAIL_STARTS="glm-native" run_switch glm-native uncensored
check "a failed glm-native start restores the previous primary" \
  '[ "$switch_rc" = 1 ] && [ "$calls" = "idle stop:uncensored gpus start:glm-native gpus start:uncensored" ]'
run_switch deepseek glm-native
check "from glm-native to deepseek: gate, stop glm-native, wait, start, report" \
  '[ "$switch_rc" = 0 ] && [ "$calls" = "idle stop:glm-native gpus start:deepseek report:deepseek" ]'
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
check "status names the served id and toggles GLM to uncensored whatever ran last" \
  '[ "$request_rc" = 0 ] && [ "$request_out" = "active:     glm (glm-5.3-flash-hyperflare-tp2-v16)"$'"'"'\n'"'"'"last:       deepseek"$'"'"'\n'"'"'"toggle ->   start:uncensored" ] && [ -z "$calls" ]'
run toggle
check "toggle from GLM switches to uncensored through the Hyperflare switcher" \
  '[ "$request_rc" = 0 ] && [ "$calls" = "start:uncensored report:uncensored" ]'
run glm
check "already-serving request reports without switching" '[ "$request_rc" = 0 ] && [ "$calls" = "report:glm" ]'
state; running[$DS41_CONTAINER]=0; label[$DS41_CONTAINER]=warmind-1017-native
run toggle
check "toggle from WARMIND swaps the ds41 weights to DeepSeek" \
  '[ "$request_rc" = 0 ] && [ "$calls" = "idle stop:warmind gpus start:deepseek report:deepseek" ]'
run status
check "status with nothing to suffix" '[[ "$request_out" == *"active:     warmind (warmind-1017-native)"* ]]'
state; running[$DS41_CONTAINER]=0; label[$DS41_CONTAINER]=deepseek-v4.1-flash-native
run toggle
check "toggle from DeepSeek swaps the ds41 weights to WARMIND" \
  '[ "$request_rc" = 0 ] && [ "$calls" = "idle stop:deepseek gpus start:warmind report:warmind" ]'
state; running[$UNCENSORED_CONTAINER]=0
run status
check "status names uncensored's served id and toggles uncensored to GLM" \
  '[ "$request_rc" = 0 ] && [[ "$request_out" == *"active:     uncensored (glm-5.3-flash-hyperflare-tp2-uncensored)"* ]] && [[ "$request_out" == *"toggle ->   start:glm"* ]]'
run toggle
check "toggle from uncensored switches to GLM through the Hyperflare switcher" \
  '[ "$request_rc" = 0 ] && [ "$calls" = "start:glm report:glm" ]'
run uncensored
check "an already-serving uncensored reports without switching" '[ "$request_rc" = 0 ] && [ "$calls" = "report:uncensored" ]'
run glm
check "uncensored to glm goes through the Hyperflare switcher" '[ "$request_rc" = 0 ] && [ "$calls" = "start:glm report:glm" ]'
state; running[$GLM_CONTAINER]=0
run uncensored
check "glm to uncensored goes through the Hyperflare switcher" '[ "$request_rc" = 0 ] && [ "$calls" = "start:uncensored report:uncensored" ]'
state; finished[$UNCENSORED_CONTAINER]=2026-11-14T11:00:00Z
run toggle
check "toggle with nothing running resumes uncensored" '[ "$request_rc" = 0 ] && [ "$calls" = "start:uncensored report:uncensored" ]'
state
run uncensored
check "uncensored from nothing goes straight to its switcher" '[ "$request_rc" = 0 ] && [ "$calls" = "start:uncensored report:uncensored" ]'
state; running[$GLM_NATIVE_CONTAINER]=0; label[$GLM_NATIVE_CONTAINER]=glm-5.3-uncensored-native
run status
check "status names glm-native's served id and that toggle has nowhere to go" \
  '[ "$request_rc" = 0 ] && [[ "$request_out" == *"active:     glm-native (glm-5.3-uncensored-native)"* ]] && [[ "$request_out" == *"toggle ->   error:"* ]]'
run toggle
check "toggle from glm-native is refused and touches nothing" '[ "$request_rc" = 1 ] && [ -z "$calls" ]'
run warmind
check "glm-native to warmind: gate, stop glm-native, wait, start, report" \
  '[ "$request_rc" = 0 ] && [ "$calls" = "idle stop:glm-native gpus start:warmind report:warmind" ]'
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
