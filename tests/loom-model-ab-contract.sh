#!/usr/bin/env bash
# Contract for the meaningful TypeScript Loom benchmark and its local-model arms.
# shellcheck disable=SC2016,SC2088 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$ROOT/benchmarks/loom-model-ab"
ARMS="$BENCH/scripts/arms.sh"
RUN="$BENCH/scripts/run-arm.sh"
VERIFY="$BENCH/scripts/verify-harness.sh"
VERIFY_MODELS="$BENCH/scripts/verify-run-models.sh"
GRADE="$BENCH/scripts/grade-implementation.sh"
ANON="$BENCH/scripts/anonymise.sh"
README="$BENCH/README.md"
PI_MODELS="$ROOT/pi/models.json"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for script in "$ARMS" "$RUN" "$VERIFY" "$VERIFY_MODELS" "$GRADE" "$ANON"; do
  [[ -x "$script" ]] || fail "benchmark script is not executable: $script"
  bash -n "$script"
done

# shellcheck source=benchmarks/loom-model-ab/scripts/arms.sh
source "$ARMS"
[[ "${BENCHMARK_ARM_IDS[*]}" == 'ds4 qwen glm-dflash glm-mtp' ]] \
  || fail "arm catalog changed unexpectedly: ${BENCHMARK_ARM_IDS[*]}"

for arm in "${BENCHMARK_ARM_IDS[@]}"; do
  record="$(benchmark_arm_record "$arm")" || fail "catalog rejected $arm"
  [[ "$(awk -F '\t' '{print NF}' <<<"$record")" -eq 6 ]] \
    || fail "$arm catalog record does not have six fields"
done

status=0
benchmark_arm_record unknown >/dev/null 2>&1 || status=$?
[[ "$status" -eq 2 ]] || fail "unknown arm did not fail with usage status 2"

list_output="$(bash "$RUN" --list)"
for arm in "${BENCHMARK_ARM_IDS[@]}"; do
  grep -Eq "^${arm}[[:space:]]" <<<"$list_output" || fail "--list omits $arm"
done

contains "$ARMS" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision:max'
contains "$ARMS" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max'
contains "$ARMS" 'glm53-flash-exl3-k4-vllm-sm120-v3'
contains "$ARMS" 'glm53-flash-exl3-k4-vllm-sm120-v4'
contains "$RUN" 'stale benchmark baseline:'
contains "$RUN" 'Cortex is active; cross-arm memory would contaminate this run.'
contains "$RUN" '~/.config/glm53/api-key'
contains "$RUN" 'curl --config -'
contains "$RUN" 'protocol.sha256'
contains "$RUN" 'select(type == "array" and length == 1)'
contains "$RUN" 'verify-run-models.sh'
contains "$VERIFY" '.thinkingLevelMap[$level] != null'
contains "$VERIFY" 'Pi routing lacks exact qwen/glm named targets'
contains "$GRADE" 'child_models_attested'
contains "$VERIFY" 'hidden suite and reference specification cover different FR sets'
contains "$ANON" 'glm[-_ ]?5\.?3'
contains "$ANON" 'dflash2?'
contains "$README" 'glm-mtp'
contains "$README" 'meaningful TypeScript'

if grep -Eq -- 'curl .*Authorization: Bearer' "$RUN"; then
  fail "run-arm puts its bearer token in argv"
fi

jq -e '
  .targets.qwen == {
    "model": "desktop-vllm/qwen3.8-27b",
    "thinkingLevel": "xhigh"
  } and
  .targets.glm == {
    "model": "desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp",
    "thinkingLevel": "max"
  }
' "$ROOT/pi/model-routing.json" >/dev/null || fail "Pi routing lacks exact qwen/glm targets"

jq -e '
  any(.providers["desktop-vllm"].models[];
    .id == "glm-5.3-flash-exl3-k4-vision" and
    .contextWindow == 98304 and
    .thinkingLevelMap.max == "max") and
  any(.providers["desktop-vllm"].models[];
    .id == "glm-5.3-flash-exl3-k4-vision-mtp" and
    .contextWindow == 98304 and
    .thinkingLevelMap.max == "max")
' "$PI_MODELS" >/dev/null || fail "Pi lacks a compatible GLM benchmark model"

attestation_sandbox="$(mktemp -d)"
trap 'rm -rf "$attestation_sandbox"' EXIT
cat >"$attestation_sandbox/run.json" <<'JSON'
{"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max"}
JSON
cat >"$attestation_sandbox/session.jsonl" <<'JSONL'
{"type":"message","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"agent":"brainstorm-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max"}}]}}}
{"type":"message","message":{"role":"toolResult","toolName":"loom_interactive_subagent","details":{"results":[{"agent":"specify-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"glm-5.3-flash-exl3-k4-vision-mtp","requestedModel":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max"}}]}}}
JSONL
bash "$VERIFY_MODELS" "$attestation_sandbox" >/dev/null
jq -e '.passed == true and .checked_children == 2' "$attestation_sandbox/model-attestation.json" >/dev/null \
  || fail "matching child model receipts did not attest"

sed -i 's#desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max#desktop-vllm/qwen3.8-27b:xhigh#g' \
  "$attestation_sandbox/session.jsonl"
status=0
bash "$VERIFY_MODELS" "$attestation_sandbox" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "mixed-model child did not fail attestation"
jq -e '.passed == false and (.violations | length > 0)' "$attestation_sandbox/model-attestation.json" >/dev/null \
  || fail "mixed-model attestation did not record its violation"

: >"$attestation_sandbox/session.jsonl"
bash "$VERIFY_MODELS" "$attestation_sandbox" >/dev/null
jq -e '.passed == true and .checked_children == 0' "$attestation_sandbox/model-attestation.json" >/dev/null \
  || fail "a run that spawned no children was incorrectly treated as contamination"

rm -rf "$attestation_sandbox"
trap - EXIT
printf 'PASS: Loom TypeScript benchmark supports fail-closed GLM MTP and DFlash arms\n'
