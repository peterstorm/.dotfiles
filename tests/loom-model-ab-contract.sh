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
V2="$BENCH/protocols/v2"
V2_BRIEF="$V2/frozen/brief.md"
V2_TYPES="$V2/frozen/ui-relay-types.ts"
V2_WIRE="$V2/frozen/wire-contract.md"
V2_REFERENCE="$V2/hidden/reference-spec.md"
V2_LOCK="$V2/source-lock.json"
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
V1_PROTOCOL_SHA="$(benchmark_protocol_sha "$BENCH" v1)"
V2_PROTOCOL_SHA="$(benchmark_protocol_sha "$BENCH" v2)"
[[ "${BENCHMARK_PROTOCOL_VERSIONS[*]}" == 'v1 v2' ]] \
  || fail "protocol catalog changed unexpectedly: ${BENCHMARK_PROTOCOL_VERSIONS[*]}"
[[ "$BENCHMARK_DEFAULT_PROTOCOL_VERSION" == v2 ]] || fail "v2 is not the default protocol"
status=0
benchmark_protocol_sha "$BENCH" future >/dev/null 2>&1 || status=$?
[[ "$status" -eq 2 ]] || fail "protocol hasher accepted an unknown version"
[[ "${BENCHMARK_ARM_IDS[*]}" == 'ds4 ds4-vision-r21 ds41 qwen qwen-vllm-bf16kv qwen-flash-next qwen-flash-next-v2 glm-v10-dcp2 glm-v11 sol' ]] \
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
list_v1_output="$(bash "$RUN" --protocol v1 --list)"
for arm in "${BENCHMARK_ARM_IDS[@]}"; do
  grep -Eq "^${arm}[[:space:]]" <<<"$list_output" || fail "--list omits $arm"
  grep -Eq "^${arm}[[:space:]]" <<<"$list_v1_output" || fail "v1 --list omits $arm"
done
status=0
bash "$RUN" --protocol future --list >/dev/null 2>&1 || status=$?
[[ "$status" -eq 2 ]] || fail "unknown protocol did not fail with usage status 2"

contains "$ARMS" 'desktop-vllm/deepseek-v4-flash-vision:max'
contains "$ARMS" 'ds4-flash-vision-infernal-invocation-cu133-r21-v1'
contains "$ARMS" 'switch-ds4-flash-vision-r21-v1.sh start'
contains "$ARMS" 'desktop-vllm/deepseek-v4.1-flash:max'
contains "$ARMS" 'ds41-1017-maya-exl35'
contains "$ARMS" 'switch-ds41-1017-maya-exl35.sh start'
contains "$ARMS" 'qwen38-27b-bf16-dflash2-vllm-v3'
contains "$ARMS" 'switch-qwen38-backend-v5.sh dflash2-vllm-tp1-bf16kv'
contains "$ARMS" 'desktop-vllm/qwen3.8-flash-next-fp8:xhigh'
contains "$ARMS" 'qwen38-flash-next-fp8-vllm-v1'
contains "$ARMS" 'switch-qwen38-flash-next-profile-v1.sh start'
contains "$ARMS" 'qwen38-flash-next-fp8-vllm-v2'
contains "$ARMS" 'switch-qwen38-flash-next-profile-v2.sh start'
contains "$ARMS" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10:max'
contains "$ARMS" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max'
contains "$ARMS" 'glm53-flash-exl3-k4-vllm-sm120-v10'
contains "$ARMS" 'glm53-flash-exl3-k4-vllm-sm120-v11'
contains "$RUN" 'stale benchmark baseline:'
contains "$RUN" 'A memory package (cortex/obsidian) is active'
contains "$RUN" 'Loom runtime has uncommitted changes'
contains "$RUN" 'LOOM_RUNTIME_LOADER_ROOT=$LOOM_RUNTIME PI_PROVIDER=${MODEL%%/*} PI_MODEL=${SELECTOR%%:*} PI_REASONING_LEVEL=${SELECTOR##*:} pi --model $MODEL'
contains "$RUN" 'loom_runtime_sha: $loom_runtime_sha'
contains "$RUN" 'rendered phase agents do not bind'
contains "$RUN" '~/.config/glm53/api-key'
contains "$RUN" 'curl --config -'
contains "$RUN" 'protocol.sha256'
contains "$RUN" 'select(type == "array" and length == 1)'
contains "$RUN" 'docker inspect --format='
contains "$RUN" 'Runtime profile mismatch:'
contains "$RUN" 'verify-run-models.sh'
contains "$VERIFY" '.thinkingLevelMap[$level] != null'
contains "$VERIFY" 'Pi routing does not bind local children to the parent selector'
contains "$GRADE" 'child_models_attested'
contains "$GRADE" '.current_phase == "execute"'
contains "$GRADE" '.tasks | type == "array" and length > 0 and all(.status == "pending")'
contains "$GRADE" 'planning_only_receipt'
contains "$GRADE" 'implementation_started'
contains "$GRADE" 'forbidden_execution_child'
contains "$GRADE" 'discovery-checklist.tsv'
contains "$BRIEF" 'Do not start implementation.'
contains "$BRIEF" '`current_wave` is `1`'
contains "$V2_BRIEF" '`extension_ui_request` records'
contains "$V2_BRIEF" 'child tool allowlist, not invented as a'
contains "$V2_TYPES" 'MAX_RPC_FRAME_BYTES = 4 * 1024 * 1024'
contains "$V2_TYPES" 'kind: "set-editor-text"'
contains "$V2_WIRE" '96db189bf2012378c1874b9168d328108a199df9b6d0633a23f18a9355bc21e0'
contains "$V2_WIRE" '`agent_settled` is the successful terminal event'
contains "$V2_REFERENCE" '**FR-043**'
contains "$V2_REFERENCE" 'Recursive delegation is explicitly out of scope'
contains "$OPERATOR" 'Stop at the planning boundary'
contains "$VERIFY" 'hidden suite and reference specification cover different FR sets'
contains "$VERIFY" 'v2 source lock mismatch'
contains "$GRADE" 'protocol_version // "v1"'
contains "$ANON" 'glm[-_ ]?5\.?3'
contains "$ANON" 'qwen ?3\.?8[-_ ]?flash[-_ ]?next'
contains "$ANON" 'refusing mixed-protocol blind batch'
contains "$ANON" 'dflash2?'
contains "$ANON" 'deepseek[-_ ]?v4(\.1)?[-_ ]?flash'
contains "$ANON" '(project )?maya'
contains "$README" 'glm-v11'
contains "$README" 'implementation-ready planning'

[[ "$(sha256sum "$BENCH/frozen/answer-key.md" | cut -d' ' -f1)" == '6e592bcb1b039ec84a94f5907c904a2ed8a85d1435570ee8499bcfb0238b9f2f' ]] \
  || fail "legacy v1 answer key changed"
[[ "$(sha256sum "$BENCH/frozen/brief.md" | cut -d' ' -f1)" == '29cfff690187a156da30539e0ad3c56be21932fda5cf4753e2ab37252076c280' ]] \
  || fail "legacy v1 brief changed"
[[ "$(sha256sum "$BENCH/frozen/ui-relay-types.ts" | cut -d' ' -f1)" == '909a278091bea64c332e86b09b49e01b3559c73f34374499c55eaea90db91be0' ]] \
  || fail "legacy v1 types changed"
[[ "$(sha256sum "$BENCH/hidden/reference-spec.md" | cut -d' ' -f1)" == '23cbd296822dfe58e3b0b92f04d1c7ca93bccbede23319a0562d04edb1e2ec03' ]] \
  || fail "legacy v1 reference changed"
[[ "$(sha256sum "$BENCH/hidden/ui-relay.hidden.test.ts" | cut -d' ' -f1)" == '034b32b27b96b19a2cb8329f6ffb4a0ed90d16458edef3995933228cdc6decdf' ]] \
  || fail "legacy v1 hidden suite changed"
[[ "$(sha256sum "$BENCH/rubric.md" | cut -d' ' -f1)" == '0128f47bb27830a0a53422e10dd9b211135c11d0d3183304d1e07d4ed8e4f5ee' ]] \
  || fail "legacy v1 rubric changed"
jq -e '.protocol_version == "v2" and (.sources | length == 2)' "$V2_LOCK" >/dev/null \
  || fail "v2 source lock is malformed"

if grep -Eq -- 'curl .*Authorization: Bearer' "$RUN"; then
  fail "run-arm puts its bearer token in argv"
fi

jq -e '
  [.rules[] | select(.when.parentClass == "local" or .when.parentClass == null)]
  | .[0] == {"id": "local-workloads-use-parent", "when": {"parentClass": "local"}, "use": {"kind": "parent"}}
' "$ROOT/pi/model-routing.json" >/dev/null || fail "Pi routing does not make local children inherit the parent"

jq -e '
  any(.providers["desktop-vllm"].models[];
    .id == "deepseek-v4.1-flash" and
    .contextWindow == 262144 and
    .thinkingLevelMap.max == "max") and
  any(.providers["desktop-vllm"].models[];
    .id == "deepseek-v4-flash-vision" and
    .contextWindow == 312000 and
    .thinkingLevelMap.max == "max") and
  any(.providers["desktop-vllm"].models[];
    .id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11" and
    .contextWindow == 359000 and
    .thinkingLevelMap.max == "max") and
  any(.providers["desktop-vllm"].models[];
    .id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10" and
    .contextWindow == 359000 and
    .thinkingLevelMap.max == "max")
' "$PI_MODELS" >/dev/null || fail "Pi lacks a compatible GLM benchmark model"

# Pi package entries may be objects ({source, extensions}); the memory guard
# must read their source rather than crash, and must fail closed either way.
isolation_sandbox="$(mktemp -d)"
mkdir -p "$isolation_sandbox/agents"
printf 'rendered\n' > "$isolation_sandbox/agents/brainstorm-agent.md"
cat > "$isolation_sandbox/settings.json" <<'JSON'
{"packages": [{"source": "../../dev/claude-plugins/loom", "extensions": []}, "../../dev/claude-plugins/cortex", "../../dev/claude-plugins/obsidian"]}
JSON
cp "$isolation_sandbox/settings.json" "$isolation_sandbox/settings.original.json"
git -C "$isolation_sandbox" init -q runtime
git -C "$isolation_sandbox/runtime" -c user.name=benchmark -c user.email=bench@local \
  commit -q --allow-empty -m runtime
status=0
guard_output="$(PI_CODING_AGENT_DIR="$isolation_sandbox" LOOM_RUNTIME_REPO="$isolation_sandbox/runtime" \
  bash "$RUN" --probe ds41 2>&1)" || status=$?
[[ "$status" -eq 1 && "$guard_output" == *'A memory package (cortex/obsidian) is active'* ]] \
  || fail "run-arm did not refuse an active memory package beside an object package entry: $guard_output"
PI_CODING_AGENT_DIR="$isolation_sandbox" bash "$BENCH/scripts/isolation.sh" off >/dev/null
jq -e '.packages == [{"source": "../../dev/claude-plugins/loom", "extensions": []}]' \
  "$isolation_sandbox/settings.json" >/dev/null || fail "isolation off left a memory package or dropped Loom"
printf 'arm render\n' > "$isolation_sandbox/agents/brainstorm-agent.md"
PI_CODING_AGENT_DIR="$isolation_sandbox" bash "$BENCH/scripts/isolation.sh" on >/dev/null
cmp -s "$isolation_sandbox/settings.json" "$isolation_sandbox/settings.original.json" \
  || fail "isolation on did not restore settings byte-for-byte"
[[ "$(cat "$isolation_sandbox/agents/brainstorm-agent.md")" == rendered ]] \
  || fail "isolation on did not restore the rendered agents"
PI_CODING_AGENT_DIR="$isolation_sandbox" LOOM_RUNTIME_REPO="$isolation_sandbox/runtime" \
  bash "$BENCH/scripts/isolation.sh" off >/dev/null
jq -e --arg runtime "$isolation_sandbox/runtime" '.packages == [{"source": $runtime, "extensions": []}]' \
  "$isolation_sandbox/settings.json" >/dev/null || fail "isolation off did not pin the Loom package to the runtime"
PI_CODING_AGENT_DIR="$isolation_sandbox" bash "$BENCH/scripts/isolation.sh" on >/dev/null
cmp -s "$isolation_sandbox/settings.json" "$isolation_sandbox/settings.original.json" \
  || fail "isolation on did not undo the runtime pin"
rm -rf "$isolation_sandbox"

mixed_protocol_sandbox="$(mktemp -d)"
mkdir -p "$mixed_protocol_sandbox/v1" "$mixed_protocol_sandbox/v2"
printf '%s\n' '{"protocol_sha256":"legacy"}' > "$mixed_protocol_sandbox/v1/run.json"
printf '%s\n' '{"protocol_version":"v2","protocol_sha256":"current"}' > "$mixed_protocol_sandbox/v2/run.json"
status=0
bash "$ANON" contract-mixed-protocol "$mixed_protocol_sandbox/v1" "$mixed_protocol_sandbox/v2" \
  >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "anonymiser accepted a mixed-protocol blind batch"
rm -rf "$mixed_protocol_sandbox"

attestation_sandbox="$(mktemp -d)"
trap 'rm -rf "$attestation_sandbox"' EXIT
cat >"$attestation_sandbox/run.json" <<'JSON'
{"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max"}
JSON
cat >"$attestation_sandbox/session.jsonl" <<'JSONL'
{"type":"message","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"agent":"brainstorm-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max"}}]}}}
{"type":"message","message":{"role":"toolResult","toolName":"loom_interactive_subagent","details":{"results":[{"agent":"specify-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11","requestedModel":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max"}}]}}}
JSONL
bash "$VERIFY_MODELS" "$attestation_sandbox" >/dev/null
jq -e '.passed == true and .checked_children == 2' "$attestation_sandbox/model-attestation.json" >/dev/null \
  || fail "matching child model receipts did not attest"

sed -i 's#desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max#desktop-vllm/qwen3.8-27b:xhigh#g' \
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
jq -n --arg sha "$V1_PROTOCOL_SHA" '{
  benchmark_kind: "planning-only",
  stop_before: "wave-1-implementation",
  protocol_sha256: $sha,
  model: "desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max"
}' > "$planning_run/run.json"
cat > "$planning_run/session.jsonl" <<'JSONL'
{"type":"message","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"agent":"decompose-agent","messages":[{"role":"assistant","content":[]}],"usage":{"turns":1},"model":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max","routing":{"effective":"desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max"}}]}}}
JSONL
printf 'No interview questions.\n' > "$planning_run/interview.md"
bash "$GRADE" "$planning_worktree" "$planning_run" >/dev/null
jq -e '
  .planning_complete == true and
  .protocol_version == "v1" and
  .protocol.planning_only_receipt == true and
  .protocol.implementation_started == false and
  .protocol.forbidden_execution_child == false and
  .protocol.task_graph_at_execution_boundary == true
' "$planning_run/outcome.planning.json" >/dev/null \
  || fail "valid legacy v1 pre-implementation planning boundary did not pass"

v2_worktree="$planning_sandbox/v2-worktree"
v2_run="$planning_sandbox/v2-run"
cp -a "$planning_worktree" "$v2_worktree"
mkdir -p "$v2_run"
cp "$V2_TYPES" "$v2_worktree/engine/src/core/ui-relay-types.ts"
cp "$V2_WIRE" "$v2_worktree/engine/src/core/ui-relay-wire-contract.md"
git -C "$v2_worktree" add engine/src/core/ui-relay-types.ts engine/src/core/ui-relay-wire-contract.md
git -C "$v2_worktree" -c user.name=benchmark -c user.email=bench@local commit -qm 'v2 frozen contract'
git -C "$v2_worktree" rev-parse HEAD > "$v2_run/base_sha"
v2_spec="$v2_worktree/.claude/specs/ui-relay/spec.md"
jq --arg spec "$v2_spec" '.spec_file = $spec' \
  "$v2_worktree/.claude/state/active_task_graph.json" \
  > "$v2_worktree/.claude/state/active_task_graph.json.tmp"
mv "$v2_worktree/.claude/state/active_task_graph.json.tmp" \
  "$v2_worktree/.claude/state/active_task_graph.json"
jq -n --arg sha "$V2_PROTOCOL_SHA" '{
  benchmark_kind: "planning-only",
  protocol_version: "v2",
  stop_before: "wave-1-implementation",
  protocol_sha256: $sha,
  model: "desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11:max"
}' > "$v2_run/run.json"
cp "$planning_run/session.jsonl" "$planning_run/interview.md" "$v2_run/"
bash "$GRADE" "$v2_worktree" "$v2_run" >/dev/null
jq -e '
  .planning_complete == true and
  .protocol_version == "v2" and
  .protocol.frozen_file_intact == true
' "$v2_run/outcome.planning.json" >/dev/null \
  || fail "valid v2 pre-implementation planning boundary did not pass"
grep -Fq $'FR-043\t' "$v2_run/discovery-checklist.tsv" \
  || fail "v2 grader did not use the v2 discovery reference"

stale_protocol_run="$planning_sandbox/v2-stale-protocol-run"
mkdir -p "$stale_protocol_run"
cp "$v2_run"/{base_sha,run.json,session.jsonl,interview.md} "$stale_protocol_run/"
jq '.protocol_sha256 = "stale"' "$stale_protocol_run/run.json" > "$stale_protocol_run/run.json.tmp"
mv "$stale_protocol_run/run.json.tmp" "$stale_protocol_run/run.json"
status=0
bash "$GRADE" "$v2_worktree" "$stale_protocol_run" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "planning grader accepted a stale protocol SHA"
jq -e '.planning_complete == false and .protocol.planning_only_receipt == false' \
  "$stale_protocol_run/outcome.planning.json" >/dev/null \
  || fail "planning grader did not record stale protocol receipt failure"

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

# Interview answering is mechanical where the evidence is: interview.sh
# reproduces the drift that voided ds41-2 and ds41-3 and refuses to log it.
INTERVIEW="$BENCH/scripts/interview.sh"
[[ -x "$INTERVIEW" ]] || fail "interview helper is not executable: $INTERVIEW"
bash -n "$INTERVIEW"
node --check "$BENCH/scripts/interview.mjs"
interview_sandbox="$(mktemp -d)"
trap 'rm -rf "$interview_sandbox"' EXIT
jq -n '{protocol_version: "v2"}' > "$interview_sandbox/run.json"
JUDGEMENT='Use your judgement and record the decision in the spec.'
SHELL_NO='No. Out of scope for this task.'
cat > "$interview_sandbox/interview.md" <<EOF
## Specify interview

**Q1.** Out of scope: Confirm each candidate is OUT of scope for this spec.

**A1.** $SHELL_NO

**Q2.** Error diagnostics: What shape should RelayError.message take? (Error-handling philosophy / observability)

**A2.** $JUDGEMENT

**Q3.** Coverage: What coverage/verification bar must the deliverable meet?

**A3.** $JUDGEMENT

**Q4.** Primary NFR axis: What breaks ties? (NFR)

**A4.** Correctness first, then clarity. Throughput and latency do not matter — this core runs a handful of times per phase.

**Q5.** Chunk memory: How should decodeChunk handle a large chunk? (NFR-001 memory bound)

**A5.** A few dozen frames per session at most. Do not optimise.

**Q6.** Done: What proves the work done?

**A6.** bunx tsc --noEmit clean, your own tests pass, no file outside ui-relay.ts and its test file modified.

**Q7.** Retries: What happens on retry?

**A7.** Retry three times with backoff.

## Architecture approach gate

**Q8.** Which internal architecture? (A recommended)

**A8.** Approved — selected A (recommended), no commentary.
EOF
status=0
interview_report="$(bash "$INTERVIEW" "$interview_sandbox" check)" || status=$?
[[ "$status" -eq 1 ]] || fail "interview check accepted an ignored tagged topic and an improvised answer"
grep -Fq "ERROR Q2 tagged-topic-ignored: the question tags 'Observability' and 'Error handling philosophy'" <<<"$interview_report" \
  || fail "interview check missed a judgement answer to a question that tags two key topics"
grep -Fq 'WARN Q1 polarity' <<<"$interview_report" || fail "interview check missed a bare 'No.' to a confirm question"
grep -Fq "WARN Q3 possible-coverage: judgement line, but the question mentions 'Testability bar'" <<<"$interview_report" \
  || fail "interview check did not surface a covered-looking question answered with judgement"
grep -Fq "WARN Q6 not-verbatim: 'Definition of done'" <<<"$interview_report" \
  || fail "interview check did not separate a formatting difference from improvisation"
grep -Fq 'ERROR Q7 improvised' <<<"$interview_report" || fail "interview check accepted an improvised answer"
if grep -Eq 'Q4 |Q5 |Q8 ' <<<"$interview_report"; then
  fail "interview check flagged a matching tag, a requirement id, or an approval gate"
fi
grep -Fq '7 exchanges, 2 error(s), 3 warning(s)' <<<"$interview_report" \
  || fail "interview check miscounted: $(tail -1 <<<"$interview_report")"

[[ "$(bash "$INTERVIEW" "$interview_sandbox" answer judgement)" == "$JUDGEMENT" ]] \
  || fail "interview answer did not print the judgement line verbatim"
[[ "$(bash "$INTERVIEW" "$interview_sandbox" answer 14)" == "$SHELL_NO" ]] \
  || fail "interview answer did not print topic 14 verbatim"
bash "$INTERVIEW" "$interview_sandbox" suggest 'Errors: what shape? (Error-handling philosophy)' \
  | grep -Fq 'TAGGED' || fail "interview suggest did not bind a tagged topic"

rm "$interview_sandbox/interview.md"
status=0
bash "$INTERVIEW" "$interview_sandbox" log 'Errors: what shape? (Observability)' judgement >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 && ! -e "$interview_sandbox/interview.md" ]] \
  || fail "interview log accepted the judgement line for a tagged question"
[[ "$(bash "$INTERVIEW" "$interview_sandbox" log 'Errors: what shape? (Observability)' 8)" \
  == 'None in the core. Effects are returned as values for the shell to act on.' ]] \
  || fail "interview log did not print the chosen scripted answer"
bash "$INTERVIEW" "$interview_sandbox" log 'Retries: what happens on retry?' judgement >/dev/null
bash "$INTERVIEW" "$interview_sandbox" check | grep -Fq '2 exchanges, 0 error(s), 0 warning(s)' \
  || fail "interview log did not write a log its own check accepts"
grep -Fq '**Q2.** Retries: what happens on retry?' "$interview_sandbox/interview.md" \
  || fail "interview log did not number exchanges consecutively"
rm -rf "$interview_sandbox"
trap - EXIT

printf 'PASS: Loom planning benchmark stops before implementation across all local-model arms\n'
