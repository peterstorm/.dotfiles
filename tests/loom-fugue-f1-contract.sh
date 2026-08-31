#!/usr/bin/env bash
# Contract and mutant tests for the Fugue F1 planning benchmark.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$ROOT/benchmarks/loom-fugue-f1"
SUITE="$BENCH/suite.sh"
RUN="$BENCH/scripts/run-arm.sh"
GRADE="$BENCH/scripts/grade-planning.sh"
ANON="$BENCH/scripts/anonymise.sh"
ISOLATION="$BENCH/scripts/isolation.sh"
CHILD_OUTPUTS="$BENCH/scripts/verify-child-outputs.sh"
FUGUE="${FUGUE_REPO:-$HOME/dev/agentic/fugue}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }

for script in "$SUITE" "$RUN" "$GRADE" "$ANON" "$ISOLATION" "$CHILD_OUTPUTS" "$BENCH/scripts/baseline.sh" "$BENCH/scripts/verify-harness.sh"; do
  [[ -x "$script" ]] || fail "script is not executable: $script"
  bash -n "$script"
done
# shellcheck source=benchmarks/loom-fugue-f1/suite.sh
source "$SUITE"
# shellcheck source=benchmarks/loom-model-ab/scripts/arms.sh
source "$ROOT/benchmarks/loom-model-ab/scripts/arms.sh"
PROTOCOL_SHA="$(fugue_protocol_sha "$BENCH")"
[[ "$FUGUE_SUITE_ID" == 'fugue-f1-map-v1' && "$FUGUE_PROTOCOL_VERSION" == v1 ]] || fail 'suite identity drifted'
[[ "$PROTOCOL_SHA" == 'd2629e9eb966e25364e24a34423e55247040344115874dc2f2de5fee415beed1' ]] || fail 'immutable protocol hash changed'
ARM_LIST="$(bash "$RUN" --list | tail -n +2)"
[[ "$(wc -l <<<"$ARM_LIST")" -eq 9 ]] || fail 'local arm list is incomplete'
grep -q '^glm-v10-dcp2 ' <<<"$ARM_LIST" || fail 'v10 arm is absent'
! grep -q '^sol ' <<<"$ARM_LIST" || fail 'cloud arm leaked into the local-only F1 harness'
[[ "$(fugue_benchmark_arm_record glm-v8 | cut -f2)" == 'glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v8' ]] || fail 'v8 arm identity drifted'

contains "$BENCH/frozen/brief.md" 'one statically declared worker computation'
contains "$BENCH/frozen/brief.md" 'Do not implement anything.'
contains "$BENCH/frozen/answer-key.md" 'Every supported checkpointer must agree'
contains "$BENCH/hidden/reference-spec.md" '**FR-040**'
contains "$BENCH/hidden/reference-spec.md" 'in-memory and Redis ignore options'
contains "$BENCH/rubric.md" '104'
contains "$RUN" 'curl --config -'
contains "$RUN" 'loom_runtime_sha'
contains "$GRADE" 'child_outputs_attested'
contains "$GRADE" 'task_identity_present'
contains "$GRADE" 'cross_run_contaminated'
contains "$ANON" 'refusing mixed-suite/protocol/source blind batch'
contains "$BENCH/scripts/rpc-driver.ts" 'setInterval(stopAtBoundary, 50)'
if rg -n 'tmux|send-keys' "$BENCH/scripts" --glob '!verify-harness.sh'; then fail 'benchmark scripts use tmux'; fi

reference_frs="$(mktemp)"
scenario_frs="$(mktemp)"
grep -oE '^- \*\*FR-[0-9]+' "$BENCH/hidden/reference-spec.md" | grep -oE 'FR-[0-9]+' | sort -u > "$reference_frs"
grep -oE '\[FR-[0-9]+\]' "$BENCH/hidden/acceptance-scenarios.md" | tr -d '[]' | sort -u > "$scenario_frs"
cmp -s "$reference_frs" "$scenario_frs" || fail 'FR/scenario coverage differs'
[[ "$(wc -l < "$reference_frs")" -eq 40 ]] || fail 'expected 40 FRs'
rm -f "$reference_frs" "$scenario_frs"

bun test "$BENCH/scripts/rpc-driver.test.ts" >/dev/null

isolation_sandbox="$(mktemp -d)"
mkdir -p "$isolation_sandbox/agent"
cat > "$isolation_sandbox/agent/settings.json" <<'JSON'
{"packages":["git:example/cortex","git:example/obsidian","git:example/keep"]}
JSON
cp "$isolation_sandbox/agent/settings.json" "$isolation_sandbox/original.json"
TEST_RUNTIME="$(realpath -e "${LOOM_RUNTIME_REPO:-$HOME/dev/claude-plugins/loom-benchmark-runtime-3815f65}")"
PI_CODING_AGENT_DIR="$isolation_sandbox/agent" LOOM_RUNTIME_REPO="$TEST_RUNTIME" bash "$ISOLATION" off >/dev/null
jq -e --arg runtime "$TEST_RUNTIME" '.packages == ["git:example/keep", $runtime]' "$isolation_sandbox/agent/settings.json" >/dev/null || fail 'isolation did not remove memory packages and pin Loom'
PI_CODING_AGENT_DIR="$isolation_sandbox/agent" LOOM_RUNTIME_REPO="$TEST_RUNTIME" bash "$ISOLATION" status >/dev/null
PI_CODING_AGENT_DIR="$isolation_sandbox/agent" LOOM_RUNTIME_REPO="$TEST_RUNTIME" bash "$ISOLATION" on >/dev/null
cmp -s "$isolation_sandbox/original.json" "$isolation_sandbox/agent/settings.json" || fail 'isolation restore was not exact'
rm -rf "$isolation_sandbox"

child_sandbox="$(mktemp -d)"
cat > "$child_sandbox/session.jsonl" <<'JSONL'
{"type":"message","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"agent":"specify-agent","messages":[{"role":"assistant","content":[{"type":"text","text":"Specification complete."}]}],"usage":{"turns":1}}]}}}
JSONL
bash "$CHILD_OUTPUTS" "$child_sandbox" >/dev/null
jq -e '.passed == true and .checked_children == 1' "$child_sandbox/child-output-attestation.json" >/dev/null || fail 'textual child did not attest'
sed -i 's/{"type":"text","text":"Specification complete."}/{"type":"thinking","thinking":"done"}/' "$child_sandbox/session.jsonl"
status=0
bash "$CHILD_OUTPUTS" "$child_sandbox" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail 'reasoning-only child passed attestation'
rm -rf "$child_sandbox"

if [[ "${1:-}" == --self-check ]]; then
  printf 'PASS: Fugue F1 benchmark static contract\n'
  exit 0
fi

TARGET_SHA="$(fugue_source_lock_value "$BENCH" '.target.base_sha')"
RUNTIME_SHA="$(fugue_source_lock_value "$BENCH" '.loom_runtime.base_sha')"
TARGET_REPOSITORY="$(fugue_source_lock_value "$BENCH" '.target.repository')"
PI_VERSION="$(fugue_source_lock_value "$BENCH" '.pi.version')"
ARM='glm-mtp'
IFS=$'\t' read -r MODEL SERVED CONTEXT PROFILE _ <<<"$(fugue_benchmark_arm_record "$ARM")"
PI_MODELS_SHA="$(sha256sum "$ROOT/pi/models.json" | cut -d' ' -f1)"
sandbox="$(mktemp -d)"
worktree="$sandbox/worktree"
valid_run="$sandbox/valid-run"
cleanup() {
  git -C "$FUGUE" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  rm -rf "$sandbox"
  rm -rf "$BENCH/blind/contract-fugue-f1" "$BENCH/blind/contract-fugue-f1.mapping.txt"
}
trap cleanup EXIT
git -C "$FUGUE" worktree add --detach "$worktree" "$TARGET_SHA" >/dev/null
mkdir -p "$worktree/.claude/specs/fugue-f1-map" "$worktree/.claude/plans" "$worktree/.claude/state" "$valid_run"
cat > "$worktree/.claude/specs/fugue-f1-map/brainstorm.md" <<'EOF'
# Map Node brainstorm
Bounded runtime-width fan-out creates indexed Map Instances and one Gathered Output.
EOF
cat > "$worktree/.claude/specs/fugue-f1-map/spec.md" <<'EOF'
# Map Node specification
A map node performs bounded runtime-width fan-out and durable ordered scatter-gather.
EOF
cat > "$worktree/.claude/specs/fugue-f1-map/plan-alignment.md" <<'EOF'
# Alignment
The map node plan agrees with the static DAG and composite checkpoint ADR.
EOF
cat > "$worktree/.claude/plans/fugue-f1-map.md" <<'EOF'
# Map Node plan
Implement runtime-width Map Instances, ordered gather, checkpointer parity, and properties.
EOF
cat > "$worktree/.claude/state/active_task_graph.json" <<JSON
{
  "current_phase": "execute",
  "current_wave": 1,
  "spec_dir": ".claude/specs/fugue-f1-map",
  "spec_file": "$worktree/.claude/specs/fugue-f1-map/spec.md",
  "plan_file": ".claude/plans/fugue-f1-map.md",
  "tasks": [{"id":"T1","status":"pending"}],
  "executing_tasks": [],
  "wave_gates": {"1":{"impl_complete":false,"reviews_complete":false,"tests_passed":null}}
}
JSON
printf '%s\n' "$TARGET_SHA" > "$valid_run/base_sha"
printf '# Interview\n\nNo unscripted answers.\n' > "$valid_run/interview.md"
cat > "$valid_run/session.jsonl" <<JSONL
{"type":"message","message":{"role":"toolResult","toolName":"subagent","details":{"results":[{"agent":"decompose-agent","messages":[{"role":"assistant","content":[{"type":"text","text":"Decomposition complete."}]}],"usage":{"turns":1},"model":"$MODEL","routing":{"effective":"$MODEL"}}]}}}
JSONL
cat > "$valid_run/driver-receipt.json" <<'JSON'
{"passed":true,"boundary_at":"2026-08-30T00:00:00Z","abort_sent":true,"agent_settled":true,"session_copied":true,"protocol_error":null}
JSON
jq -n \
  --arg suite "$FUGUE_SUITE_ID" --arg version "$FUGUE_PROTOCOL_VERSION" --arg protocol "$PROTOCOL_SHA" \
  --arg arm "$ARM" --arg model "$MODEL" --arg served "$SERVED" --arg profile "$PROFILE" \
  --argjson context "$CONTEXT" --arg image_config 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  --arg pi_models_sha "$PI_MODELS_SHA" --arg repository "$TARGET_REPOSITORY" --arg target "$TARGET_SHA" \
  --arg runtime "$RUNTIME_SHA" --arg pi "$PI_VERSION" '{
    benchmark_kind:"planning-only", suite_id:$suite, protocol_version:$version,
    protocol_sha256:$protocol, stop_before:"wave-1-implementation", arm:$arm, model:$model,
    served_model:$served, profile_container:$profile, context_window:$context,
    image_config:$image_config, pi_models_sha256:$pi_models_sha,
    target:{repository:$repository,base_sha:$target}, loom_runtime_sha:$runtime,
    pi_version:$pi, baseline_typecheck:"clean"
  }' > "$valid_run/run.json"

bash "$GRADE" "$worktree" "$valid_run" >/dev/null
jq -e '.planning_complete == true and .protocol.child_outputs_attested == true and .protocol.task_identity_present == true' \
  "$valid_run/outcome.planning.json" >/dev/null || fail 'valid planning fixture did not pass'
[[ "$(tail -n +2 "$valid_run/discovery-checklist.tsv" | wc -l)" -eq 40 ]] || fail 'discovery checklist does not have 40 rows'

contaminated="$sandbox/contaminated"
cp -a "$valid_run" "$contaminated"
printf '%s\n' '<!-- CORTEX_MEMORY_START -->' >> "$contaminated/session.jsonl"
status=0
bash "$GRADE" "$worktree" "$contaminated" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail 'Cortex-contaminated fixture passed'
jq -e '.planning_complete == false and .protocol.cross_run_contaminated == true' "$contaminated/outcome.planning.json" >/dev/null || fail 'contamination not recorded'

empty_child="$sandbox/empty-child"
cp -a "$valid_run" "$empty_child"
sed -i 's/{"type":"text","text":"Decomposition complete."}/{"type":"thinking","thinking":"done"}/' "$empty_child/session.jsonl"
status=0
bash "$GRADE" "$worktree" "$empty_child" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail 'reasoning-only child fixture passed'
jq -e '.planning_complete == false and .protocol.child_outputs_attested == false' "$empty_child/outcome.planning.json" >/dev/null || fail 'empty child not recorded'

printf '\nexport const implementationStarted = true;\n' >> "$worktree/packages/framework/src/index.ts"
implementation="$sandbox/implementation"
cp -a "$valid_run" "$implementation"
status=0
bash "$GRADE" "$worktree" "$implementation" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail 'implementation fixture passed planning gate'
jq -e '.planning_complete == false and .protocol.implementation_started == true' "$implementation/outcome.planning.json" >/dev/null || fail 'implementation start not recorded'

git -C "$worktree" reset --hard "$TARGET_SHA" >/dev/null
second_valid="$sandbox/second-valid"
cp -a "$valid_run" "$second_valid"
bash "$ANON" contract-fugue-f1 "$valid_run" "$second_valid" >/dev/null
jq -e --arg suite "$FUGUE_SUITE_ID" '.suite_id == $suite' "$BENCH/blind/contract-fugue-f1/suite.json" >/dev/null || fail 'blind suite receipt missing'
rm -rf "$BENCH/blind/contract-fugue-f1" "$BENCH/blind/contract-fugue-f1.mapping.txt"

mixed="$sandbox/mixed"
cp -a "$valid_run" "$mixed"
jq '.loom_runtime_sha = "wrong"' "$mixed/run.json" > "$mixed/run.json.tmp"
mv "$mixed/run.json.tmp" "$mixed/run.json"
status=0
bash "$ANON" contract-fugue-f1 "$valid_run" "$mixed" >/dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail 'mixed source identity blind batch passed'

printf 'PASS: Fugue F1 planning benchmark fails closed across valid and mutant evidence\n'
