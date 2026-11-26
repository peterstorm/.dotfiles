#!/usr/bin/env bash
# Behavioural tests for the runtime-neutral idle gate every cutover depends on
# (inference_active_requests / inference_active_runtime /
# inference_require_idle_endpoint in
# scripts/inference/shared/inference-profile-catalog.sh). curl, sleep and ss are
# stubbed as shell functions; no network, no engine, no Docker.
#
# Two subjects, one seam:
# - reading in-flight requests from whichever runtime owns :8000, failing closed
#   when the reading cannot be trusted;
# - the drain policy on top of it, which used to sample at a fixed 0/3/3 and
#   refuse on the FIRST busy sample. On 2026-11-26 that failed three /switch
#   attempts with one request in flight (a long reasoning turn and a bursty
#   client), then let the same switch through minutes later with the same
#   clients still connected.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$ROOT/scripts/inference/shared/inference-profile-catalog.sh"

failures=0
cases=0
expect() {
  cases=$((cases + 1))
  if [ "$2" != "$3" ]; then
    failures=$((failures + 1))
    printf 'FAIL %s: got %q, expected %q\n' "$1" "$2" "$3" >&2
  fi
}

# One body per endpoint; an unset body means that source is down (curl -f fails).
declare -A body=()
curl() {
  local url="${*: -1}"
  [ -n "${body[$url]+set}" ] || return 22
  printf '%s\n' "${body[$url]}"
}
sleep() { :; }
DS4=http://127.0.0.1:8010/metrics
FLARE=http://127.0.0.1:8011/metrics
ENGINE=http://127.0.0.1:8000/metrics
active() { local out rc=0; out="$(inference_active_requests 2>/dev/null)" || rc=$?; printf '%s/%s' "$out" "$rc"; }

# --- reading in-flight requests --------------------------------------------
body=([$FLARE]=$'hyperflare:requests_running{model_name="glm"} 2\nhyperflare:requests_waiting{model_name="glm"} 1\nhyperflare:requests_total{model_name="glm"} 99')
expect "hyperflare busy sums running+waiting only" "$(active)" "3/0"

body=([$FLARE]=$'hyperflare:requests_running{model_name="glm"} 0\nhyperflare:requests_waiting{model_name="glm"} 0')
expect "hyperflare idle" "$(active)" "0/0"

body=([$DS4]=$'ds4:requests_running{model_name="warmind"} 1\nds4:requests_waiting{model_name="warmind"} 0' [$FLARE]=$'hyperflare:requests_running{model_name="glm"} 5')
expect "ds4 bridge answers first" "$(active)" "1/0"

body=([$ENGINE]=$'vllm:num_requests_running{model_name="q"} 1\nvllm:num_requests_waiting{model_name="q"} 2')
expect "vllm on :8000 when both bridges are down" "$(active)" "3/0"

body=([$ENGINE]=$'sglang:num_running_reqs{model_name="q"} 0\nsglang:num_queue_reqs{model_name="q"} 0')
expect "sglang idle" "$(active)" "0/0"

body=([$ENGINE]=$'llamacpp:prompt_tokens_total 5')
expect "unknown runtime fails closed" "$(active)" "/1"

# A family that lost one of its two gauges must not sum short and read as idle.
body=([$ENGINE]=$'vllm:num_requests_running{model_name="q"} 1')
expect "vllm without its waiting gauge fails closed" "$(active)" "/1"
body=([$ENGINE]=$'sglang:num_running_reqs{model_name="q"} 0')
expect "sglang without its queue gauge fails closed" "$(active)" "/1"

body=()
expect "nothing answers fails closed" "$(active)" "/1"

# --- naming the runtime a refusal is about ---------------------------------
body=([$DS4]=$'ds4:requests_running{model_name="warmind"} 1')
expect "the ds4 bridge names the ds4-native runtime" "$(inference_active_runtime)" ds4-native
body=([$FLARE]=$'hyperflare:requests_running{model_name="glm"} 1')
expect "the Hyperflare bridge names the hyperflare runtime" "$(inference_active_runtime)" hyperflare
body=([$ENGINE]=$'vllm:num_requests_running{model_name="q"} 0\nvllm:num_requests_waiting{model_name="q"} 0')
expect "vLLM metrics name the vllm runtime" "$(inference_active_runtime)" vllm
body=([$ENGINE]=$'sglang:num_running_reqs{model_name="q"} 0\nsglang:num_queue_reqs{model_name="q"} 0')
expect "SGLang metrics name the sglang runtime" "$(inference_active_runtime)" sglang
body=([$ENGINE]=$'llamacpp:prompt_tokens_total 5')
expect "an unrecognised answer is an unknown runtime" "$(inference_active_runtime)" "an unknown runtime"

# --- the gate: drain policy, bound, attribution ----------------------------
# The drain samples inference_active_requests; the clock the budget is measured
# on is SECONDS, advanced by the sleep stub so the suite stays instant.
# The gate reads the sample through a command substitution (a subshell), so the
# scripted sequence lives in files: a shell variable would reset on every read.
sample_queue="$(mktemp)"
sample_log="$(mktemp)"
trap 'rm -f "$sample_queue" "$sample_log" "${gate_file:-}"' EXIT
DEFAULT_SAMPLE=0
sample_calls=0
slept=0
inference_active_requests() {
  printf 'x' >>"$sample_log"
  local next="${DEFAULT_SAMPLE}"
  if [ -s "$sample_queue" ]; then
    next="$(head -n 1 "$sample_queue")"
    tail -n +2 "$sample_queue" >"$sample_queue.next" && mv "$sample_queue.next" "$sample_queue"
  fi
  [ "$next" != unreadable ] || return 1
  printf '%s\n' "$next"
}
sleep() {
  slept=$((slept + $1))
  SECONDS=$((SECONDS + $1))
}
SS_OUTPUT=""
SS_RC=0
ss() {
  [ -z "$SS_OUTPUT" ] || printf '%s\n' "$SS_OUTPUT"
  return "$SS_RC"
}

INFERENCE_IDLE_SAMPLE_SECONDS=2
INFERENCE_IDLE_STREAK=3
INFERENCE_IDLE_WAIT_SECONDS=60

# The gate runs in this shell and its output is captured through a file.
gate_file="$(mktemp)"
gate_rc=0
gate_out=""
run_gate() {
  : >"$sample_queue"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" >"$sample_queue"
  : >"$sample_log"
  slept=0
  SECONDS=0
  gate_rc=0
  : >"$gate_file"
  inference_require_idle_endpoint >"$gate_file" 2>&1 || gate_rc=$?
  gate_out="$(<"$gate_file")"
  sample_calls="$(wc -c <"$sample_log" | tr -d ' ')"
}

DEFAULT_SAMPLE=0
run_gate 0 0 0
expect "gate passes when idle" "$gate_rc" 0
expect "the success line reports the streak the gate proved" \
  "$gate_out" "IDLE GATE: no running or waiting requests across 3 samples"
expect "an idle engine is sampled the streak, twice apart" "$sample_calls/$slept" "3/4"

# The regression: one busy sample delays the cutover instead of failing it.
run_gate 1 0 0 0
expect "one busy sample drains instead of refusing" "$gate_rc" 0
expect "the drained cutover took the busy sample plus a full streak" "$sample_calls" 4

# The streak is consecutive, not cumulative.
run_gate 0 0 2 0 0 0
expect "a busy sample restarts the streak" "$sample_calls" 6

# Bounded: a busy engine is still refused, naming the count, the budget and who.
body=([$FLARE]=$'hyperflare:requests_running{model_name="glm"} 3\nhyperflare:requests_waiting{model_name="glm"} 0')
SS_OUTPUT=$'0 0 192.168.0.80:8000 192.168.0.28:47802\n0 0 192.168.0.80:8000 192.168.0.30:51000\n0 0 192.168.0.80:8000 192.168.0.28:45406'
INFERENCE_IDLE_WAIT_SECONDS=6
DEFAULT_SAMPLE=3
run_gate
expect "a busy engine is refused once the budget runs out" "$gate_rc" 1
expect "the refusal counts the requests and names the budget" \
  "$gate_out" "error: 3 request(s) still running or waiting after 6 s on hyperflare; peers connected to :8000: 192.168.0.28,192.168.0.30; refusing cutover"
expect "waiting never exceeds the budget" "$([ "$slept" -le "$INFERENCE_IDLE_WAIT_SECONDS" ] && echo yes)" yes
expect "the budget bounds the sampling" "$sample_calls" 4

# An unreadable reading is refused at once: an unobservable runtime is never
# treated as idle, and never drains a budget it cannot observe.
INFERENCE_IDLE_WAIT_SECONDS=60
run_gate unreadable
expect "an unreadable reading refuses immediately" "$gate_rc/$sample_calls/$slept" "1/1/0"
expect "the unreadable refusal says what could not be read" \
  "$gate_out" "error: cannot read in-flight requests of the active profile; refusing cutover"

# A budget too small to complete the streak refuses as "never stayed idle", not
# as "requests still running" — the last reading was zero.
INFERENCE_IDLE_WAIT_SECONDS=1
DEFAULT_SAMPLE=0
run_gate
expect "an exhausted budget with an idle engine is still a refusal" "$gate_rc" 1
expect "that refusal does not claim a request was running" \
  "$gate_out" "error: the engine did not stay idle across 3 samples within 1 s; refusing cutover"

# Attribution is best effort: an unavailable ss weakens the message, never the gate.
SS_RC=127
SS_OUTPUT=""
INFERENCE_IDLE_WAIT_SECONDS=0
DEFAULT_SAMPLE=1
run_gate
expect "an unavailable ss reports unknown peers" \
  "$gate_out" "error: 1 request(s) still running or waiting after 0 s on hyperflare; peers connected to :8000: unknown; refusing cutover"
SS_RC=0

# --- one gate, not a copy per switcher -------------------------------------
# Every switcher that gates a cutover calls the catalog's gate by name; no
# switcher keeps a local alias, a private body or its own sample loop.
expect "no switcher keeps a local gate alias" \
  "$(grep -rl '^require_idle_endpoint()' "$ROOT/scripts/inference" | wc -l | tr -d ' ')" 0
# A switcher about to stop a running profile gates first, by the catalog's name.
ungated=""
while IFS= read -r switcher; do
  guarded="$(awk '
    index($0, "${#previous[@]}") && index($0, "-gt 0 ]; then") { armed = 1; next }
    armed && /^[[:space:]]*$/ { next }
    armed { print; exit }
  ' "$switcher")"
  [ -n "$guarded" ] || continue
  case "$guarded" in
    *inference_require_idle_endpoint*) ;;
    *) ungated="$ungated$(basename "$switcher") " ;;
  esac
done < <(find "$ROOT/scripts/inference" -name 'switch-*.sh')
expect "every switcher that stops a running profile gates first" "$ungated" ""
expect "no switcher carries its own sample loop" \
  "$(grep -rls 'for delay in 0 3 3' "$ROOT/scripts/inference" | wc -l | tr -d ' ')" 0

if [ "$failures" -ne 0 ]; then
  echo "idle gate unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "idle gate unit: PASS ($cases checks)"
