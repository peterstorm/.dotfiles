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

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for command in git jq node sha256sum; do
  command -v "$command" >/dev/null || fail "required command is unavailable: $command"
done
required_files=("$PI_MODELS" "$PROFILE_CATALOG" "$BASELINE")
while IFS= read -r protocol_file; do
  required_files+=("$BENCH_DIR/$protocol_file")
done < <(benchmark_protocol_files)
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

reference_frs="$(mktemp)"
test_frs="$(mktemp)"
trap 'rm -f "$reference_frs" "$test_frs"' EXIT
grep -oE '^- \*\*FR-[0-9]+' "$BENCH_DIR/hidden/reference-spec.md" \
  | grep -oE 'FR-[0-9]+' | sort -u > "$reference_frs"
grep -oE '\[FR-[0-9]+\]' "$BENCH_DIR/hidden/ui-relay.hidden.test.ts" \
  | tr -d '[]' | sort -u > "$test_frs"
if ! cmp -s "$reference_frs" "$test_frs"; then
  diff -u "$reference_frs" "$test_frs" >&2 || true
  fail "hidden suite and reference specification cover different FR sets"
fi

for script in \
  "$BENCH_DIR/scripts/arms.sh" \
  "$BENCH_DIR/scripts/run-arm.sh" \
  "$BENCH_DIR/scripts/baseline.sh" \
  "$BENCH_DIR/scripts/grade-implementation.sh" \
  "$BENCH_DIR/scripts/anonymise.sh" \
  "$BENCH_DIR/scripts/isolation.sh"; do
  bash -n "$script" || fail "shell syntax check failed: $script"
done

mapfile -t PROTOCOL_FILES < <(benchmark_protocol_files)
PROTOCOL_SHA="$({
  cd "$BENCH_DIR"
  sha256sum "${PROTOCOL_FILES[@]}"
} | sha256sum | cut -d' ' -f1)"

printf 'PASS: benchmark harness is internally consistent\n'
printf '  Loom baseline: %s\n' "$LOOM_SHA"
printf '  Protocol SHA: %s\n' "$PROTOCOL_SHA"
printf '  Arms: %s\n' "${BENCHMARK_ARM_IDS[*]}"
printf 'Run an authenticated online check with: bash scripts/run-arm.sh --probe <arm>\n'
