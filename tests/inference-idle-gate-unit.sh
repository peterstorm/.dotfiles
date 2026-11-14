#!/usr/bin/env bash
# Behavioural tests for the runtime-neutral idle gate every cutover depends on
# (inference_active_requests / inference_require_idle_endpoint in
# scripts/inference/shared/inference-profile-catalog.sh). curl and sleep are
# stubbed as shell functions; no network, no engine.
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

body=()
expect "nothing answers fails closed" "$(active)" "/1"

gate() { local rc=0; inference_require_idle_endpoint >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
body=([$FLARE]=$'hyperflare:requests_running{model_name="glm"} 0\nhyperflare:requests_waiting{model_name="glm"} 0')
expect "gate passes when idle" "$(gate)" 0
body=([$FLARE]=$'hyperflare:requests_running{model_name="glm"} 1')
expect "gate refuses in-flight work" "$(gate)" 1
body=()
expect "gate refuses when it cannot tell" "$(gate)" 1

if [ "$failures" -ne 0 ]; then
  echo "idle gate unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "idle gate unit: PASS ($cases checks)"
