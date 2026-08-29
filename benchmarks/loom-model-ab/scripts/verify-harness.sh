#!/usr/bin/env bash
# Verify that the benchmark protocol, arm catalog, Pi registrations, and Loom
# baseline agree before an attended model run.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(git -C "$BENCH_DIR" rev-parse --show-toplevel)"
LOOM="${LOOM_REPO:-$HOME/dev/claude-plugins/loom}"
# shellcheck source=benchmarks/loom-model-ab/scripts/arms.sh
source "$BENCH_DIR/scripts/arms.sh"

PI_MODELS="$ROOT/pi/models.json"
PROFILE_CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
BASELINE="$BENCH_DIR/baseline/known-failures.json"
RUN_MODELS="$BENCH_DIR/scripts/verify-run-models.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for command in git jq node sha256sum; do
  command -v "$command" >/dev/null || fail "required command is unavailable: $command"
done
required_files=("$PI_MODELS" "$PROFILE_CATALOG" "$BASELINE")
while IFS= read -r protocol_version; do
  while IFS= read -r protocol_file; do
    required_files+=("$BENCH_DIR/$protocol_file")
  done < <(benchmark_protocol_files "$protocol_version")
done < <(benchmark_protocol_versions)
for file in "${required_files[@]}"; do
  [[ -r "$file" ]] || fail "required benchmark artifact is unreadable: $file"
done

LOOM_SHA="$(git -C "$LOOM" rev-parse HEAD)" || fail "cannot resolve Loom HEAD at $LOOM"
BASELINE_SHA="$(jq -er '.base_sha' "$BASELINE")" || fail "baseline has no valid base_sha"
[[ "$LOOM_SHA" == "$BASELINE_SHA" ]] \
  || fail "baseline is stale ($BASELINE_SHA); current Loom is $LOOM_SHA; run scripts/baseline.sh"
jq -e '.typecheck == "clean" and (.total_tests | type == "number" and . > 0) and (.known_failures | type == "array")' \
  "$BASELINE" >/dev/null || fail "baseline is incomplete or its typecheck was dirty"

while IFS= read -r arm; do
  IFS=$'\t' read -r model served context profile _ label \
    <<<"$(benchmark_arm_record "$arm")"
  selector="${model#desktop-vllm/}"
  model_id="${selector%%:*}"
  thinking_level="${selector##*:}"
  [[ "$served" == "$model_id" ]] \
    || fail "$arm serves $served but its Pi selector targets $model_id"
  [[ "$context" =~ ^[1-9][0-9]*$ ]] || fail "$arm has an invalid context window: $context"
  jq -e \
    --arg id "$model_id" \
    --arg level "$thinking_level" \
    --argjson context "$context" '
      any(.providers["desktop-vllm"].models[];
        .id == $id and
        .contextWindow == $context and
        .thinkingLevelMap[$level] != null)
    ' "$PI_MODELS" >/dev/null \
    || fail "$arm ($label) disagrees with pi/models.json or pins an unsupported thinking level"
  grep -Fqx "  $profile" "$PROFILE_CATALOG" \
    || fail "$arm profile is absent from the inference profile catalog: $profile"
done < <(benchmark_arm_ids)

ROUTING="$ROOT/pi/model-routing.json"
jq -e '
  .targets.qwen == {
    "model": "desktop-vllm/qwen3.8-27b",
    "thinkingLevel": "xhigh"
  } and
  .targets.glm == {
    "model": "desktop-vllm/glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k",
    "thinkingLevel": "max"
  }
' "$ROUTING" >/dev/null || fail "Pi routing lacks exact qwen/glm named targets"

reference_frs="$(mktemp)"
test_frs="$(mktemp)"
trap 'rm -f "$reference_frs" "$test_frs"' EXIT
while IFS= read -r protocol_version; do
  reference="$(benchmark_protocol_path "$protocol_version" hidden/reference-spec.md)"
  hidden_test="$(benchmark_protocol_path "$protocol_version" hidden/ui-relay.hidden.test.ts)"
  grep -oE '^- \*\*FR-[0-9]+' "$BENCH_DIR/$reference" \
    | grep -oE 'FR-[0-9]+' | sort -u > "$reference_frs"
  grep -oE '\[FR-[0-9]+\]' "$BENCH_DIR/$hidden_test" \
    | tr -d '[]' | sort -u > "$test_frs"
  if ! cmp -s "$reference_frs" "$test_frs"; then
    diff -u "$reference_frs" "$test_frs" >&2 || true
    fail "$protocol_version hidden suite and reference specification cover different FR sets"
  fi
done < <(benchmark_protocol_versions)

V2_SOURCE_LOCK="$BENCH_DIR/protocols/v2/source-lock.json"
V2_SOURCE_SHA="$(jq -er '.loom_base_sha' "$V2_SOURCE_LOCK")" \
  || fail "v2 source lock has no Loom base SHA"
while IFS=$'\t' read -r source_path expected_sha; do
  observed_sha="$(git -C "$LOOM" show "$V2_SOURCE_SHA:$source_path" | sha256sum | cut -d' ' -f1)" \
    || fail "cannot read v2 locked source $source_path at $V2_SOURCE_SHA"
  [[ "$observed_sha" == "$expected_sha" ]] \
    || fail "v2 source lock mismatch for $source_path: expected $expected_sha, observed $observed_sha"
done < <(jq -r '.sources[] | [.path, .sha256] | @tsv' "$V2_SOURCE_LOCK")

for script in \
  "$BENCH_DIR/scripts/arms.sh" \
  "$BENCH_DIR/scripts/run-arm.sh" \
  "$BENCH_DIR/scripts/baseline.sh" \
  "$BENCH_DIR/scripts/grade-planning.sh" \
  "$RUN_MODELS" \
  "$BENCH_DIR/scripts/anonymise.sh" \
  "$BENCH_DIR/scripts/isolation.sh"; do
  bash -n "$script" || fail "shell syntax check failed: $script"
done

printf 'PASS: benchmark harness is internally consistent\n'
printf '  Loom baseline: %s\n' "$LOOM_SHA"
while IFS= read -r protocol_version; do
  PROTOCOL_SHA="$(benchmark_protocol_sha "$BENCH_DIR" "$protocol_version")"
  printf '  Protocol %s SHA: %s%s\n' "$protocol_version" "$PROTOCOL_SHA" \
    "$([[ "$protocol_version" == "$BENCHMARK_DEFAULT_PROTOCOL_VERSION" ]] && printf ' (default)' || true)"
done < <(benchmark_protocol_versions)
printf '  Arms: %s\n' "${BENCHMARK_ARM_IDS[*]}"
printf 'Run an authenticated online check with: bash scripts/run-arm.sh --probe <arm>\n'
