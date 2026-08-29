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
GRADE="$BENCH/scripts/grade-planning.sh"
ANON="$BENCH/scripts/anonymise.sh"
README="$BENCH/README.md"
BRIEF="$BENCH/frozen/brief.md"
OPERATOR="$BENCH/operator-tmux.md"
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
[[ "${BENCHMARK_ARM_IDS[*]}" == 'ds4 qwen qwen-vllm-bf16kv qwen-flash-next glm-dflash glm-mtp glm-fp8' ]] \
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

contains "$ARMS" 'qwen38-27b-bf16-dflash2-vllm-v3'
contains "$ARMS" 'switch-qwen38-backend-v5.sh dflash2-vllm-tp1-bf16kv'
contains "$ARMS" 'desktop-vllm/qwen3.8-flash-next-fp8:xhigh'
contains "$ARMS" 'qwen38-flash-next-fp8-vllm-v1'
contains "$ARMS" 'switch-qwen38-flash-next-profile-v1.sh start'
contains "$ARMS" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision:max'
contains "$ARMS" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max'
contains "$ARMS" 'desktop-vllm/glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k:max'
contains "$ARMS" 'glm53-flash-exl3-k4-vllm-sm120-v3'
contains "$ARMS" 'glm53-flash-exl3-k4-vllm-sm120-v5'
contains "$ARMS" 'glm53-flash-exl3-k4-vllm-sm120-v6'
contains "$RUN" 'stale benchmark baseline:'
contains "$RUN" 'Cortex is active; cross-arm memory would contaminate this run.'
contains "$RUN" '~/.config/glm53/api-key'
contains "$RUN" 'curl --config -'
contains "$RUN" 'protocol.sha256'
contains "$RUN" 'select(type == "array" and length == 1)'
contains "$RUN" 'docker inspect --format='
contains "$RUN" 'Runtime profile mismatch:'
contains "$RUN" 'verify-run-models.sh'
contains "$VERIFY" '.thinkingLevelMap[$level] != null'
contains "$VERIFY" 'Pi routing lacks exact qwen/glm named targets'
contains "$GRADE" 'child_models_attested'
contains "$GRADE" '.current_phase == "execute"'
contains "$GRADE" '.tasks | type == "array" and length > 0 and all(.status == "pending")'
contains "$GRADE" 'planning_only_receipt'
contains "$GRADE" 'implementation_started'
contains "$GRADE" 'forbidden_execution_child'
contains "$GRADE" 'discovery-checklist.tsv'
contains "$BRIEF" 'Do not start implementation.'
contains "$BRIEF" '`current_wave` is `1`'
contains "$OPERATOR" 'Stop at the planning boundary'
contains "$VERIFY" 'hidden suite and reference specification cover different FR sets'
contains "$ANON" 'glm[-_ ]?5\.?3'
contains "$ANON" 'dflash2?'
contains "$README" 'glm-mtp'
contains "$README" 'implementation-ready planning'

if grep -Eq -- 'curl .*Authorization: Bearer' "$RUN"; then
  fail "run-arm puts its bearer token in argv"
fi

jq -e '
  .targets.qwen == {
    "model": "desktop-vllm/qwen3.8-27b",
    "thinkingLevel": "xhigh"
  } and
  .targets.glm == {
    "model": "desktop-vllm/glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k",
    "thinkingLevel": "max"
  }
' "$ROOT/pi/model-routing.json" >/dev/null || fail "Pi routing lacks exact qwen/glm targets"

jq -e '
  any(.providers["desktop-vllm"].models[];
    .id == "glm-5.3-flash-exl3-k4-vision" and
    .contextWindow == 98304 and
    .thinkingLevelMap.max == "max") and
  any(.providers["desktop-vllm"].models[];
    .id == "glm-5.3-flash-exl3-k4-vision-mtp-384k" and
    .contextWindow == 393216 and
    .thinkingLevelMap.max == "max") and
  any(.providers["desktop-vllm"].models[];
    .id == "glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k" and
    .contextWindow == 393216 and
    .thinkingLevelMap.max == "max")
' "$PI_MODELS" >/dev/null || fail "Pi lacks a compatible GLM benchmark model"

attestation_sandbox="$(mktemp -d)"
trap 'rm -rf "$attestation_sandbox"' EXIT
cat >"$attestation_sandbox/run.json" <<'JSON'
{"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max"}
JSON
cat >"$attestation_sandbox/session.jsonl" <<'JSONL'
{"type":"message","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"agent":"brainstorm-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max"}}]}}}
{"type":"message","message":{"role":"toolResult","toolName":"loom_interactive_subagent","details":{"results":[{"agent":"specify-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"glm-5.3-flash-exl3-k4-vision-mtp-384k","requestedModel":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max"}}]}}}
JSONL
bash "$VERIFY_MODELS" "$attestation_sandbox" >/dev/null
jq -e '.passed == true and .checked_children == 2' "$attestation_sandbox/model-attestation.json" >/dev/null \
  || fail "matching child model receipts did not attest"

sed -i 's#desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max#desktop-vllm/qwen3.8-27b:xhigh#g' \
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

planning_sandbox="$(mktemp -d)"
trap 'rm -rf "$planning_sandbox"' EXIT
planning_worktree="$planning_sandbox/worktree"
planning_run="$planning_sandbox/run"
mkdir -p \
  "$planning_worktree/engine/src/core" \
  "$planning_worktree/.claude/specs/ui-relay" \
  "$planning_worktree/.claude/plans" \
  "$planning_worktree/.claude/state" \
  "$planning_run"
cp "$BENCH/frozen/ui-relay-types.ts" "$planning_worktree/engine/src/core/ui-relay-types.ts"
git -C "$planning_worktree" init -q
git -C "$planning_worktree" add engine/src/core/ui-relay-types.ts
git -C "$planning_worktree" -c user.name=benchmark -c user.email=bench@local commit -qm baseline
git -C "$planning_worktree" rev-parse HEAD > "$planning_run/base_sha"
for artifact in brainstorm spec plan-alignment; do
  printf '# %s\n' "$artifact" > "$planning_worktree/.claude/specs/ui-relay/$artifact.md"
done
printf '# plan\n' > "$planning_worktree/.claude/plans/ui-relay.md"
cat > "$planning_worktree/.claude/state/active_task_graph.json" <<'JSON'
{
  "current_phase": "execute",
  "current_wave": 1,
  "spec_dir": ".claude/specs/ui-relay",
  "spec_file": ".claude/specs/ui-relay/spec.md",
  "plan_file": ".claude/plans/ui-relay.md",
  "tasks": [{"id":"T1","status":"pending"}],
  "executing_tasks": [],
  "wave_gates": {"1":{"impl_complete":false,"reviews_complete":false,"tests_passed":null}}
}
JSON
absolute_spec="$planning_worktree/.claude/specs/ui-relay/spec.md"
jq --arg spec "$absolute_spec" '.spec_file = $spec' \
  "$planning_worktree/.claude/state/active_task_graph.json" \
  > "$planning_worktree/.claude/state/active_task_graph.json.tmp"
mv "$planning_worktree/.claude/state/active_task_graph.json.tmp" \
  "$planning_worktree/.claude/state/active_task_graph.json"
cat > "$planning_run/run.json" <<'JSON'
{
  "benchmark_kind":"planning-only",
  "stop_before":"wave-1-implementation",
  "model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max"
}
JSON
cat > "$planning_run/session.jsonl" <<'JSONL'
{"type":"message","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"agent":"decompose-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max"}}]}}}
JSONL
printf 'No interview questions.\n' > "$planning_run/interview.md"
bash "$GRADE" "$planning_worktree" "$planning_run" >/dev/null
jq -e '
  .planning_complete == true and
  .protocol.planning_only_receipt == true and
  .protocol.implementation_started == false and
  .protocol.forbidden_execution_child == false and
  .protocol.task_graph_at_execution_boundary == true
' "$planning_run/outcome.planning.json" >/dev/null \
  || fail "valid pre-implementation planning boundary did not pass"

planning_child="$planning_sandbox/run-execution-child"
mkdir -p "$planning_child"
cp "$planning_run"/{base_sha,run.json,session.jsonl,interview.md} "$planning_child/"
sed -i 's/decompose-agent/code-implementer-agent/' "$planning_child/session.jsonl"
status=0
bash "$GRADE" "$planning_worktree" "$planning_child" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "planning grader accepted an implementation child"
jq -e '.planning_complete == false and .protocol.forbidden_execution_child == true' \
  "$planning_child/outcome.planning.json" >/dev/null \
  || fail "planning grader did not record the forbidden execution child"

printf 'implementation must make this run invalid\n' > "$planning_worktree/engine/src/core/ui-relay.ts"
planning_bad="$planning_sandbox/run-bad"
mkdir -p "$planning_bad"
cp "$planning_run"/{base_sha,run.json,session.jsonl,interview.md} "$planning_bad/"
status=0
bash "$GRADE" "$planning_worktree" "$planning_bad" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "planning grader accepted a started implementation"
jq -e '.planning_complete == false and .protocol.implementation_started == true' \
  "$planning_bad/outcome.planning.json" >/dev/null \
  || fail "planning grader did not record implementation start"

rm -rf "$planning_sandbox"
trap - EXIT
if rg -n 'grade-implementation\.sh|planning \+ implementation benchmark' "$BENCH"; then
  fail "planning-only benchmark retains implementation-era harness references"
fi

printf 'PASS: Loom planning benchmark stops before implementation across all local-model arms\n'
