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

LOOM_SHA="$(jq -er '.base_sha | select(test("^[0-9a-f]{40}$"))' "$BASELINE")" \
  || fail "baseline has no valid base_sha"
[[ "$(git -C "$LOOM" rev-parse --verify --quiet "$LOOM_SHA^{commit}")" == "$LOOM_SHA" ]] \
  || fail "baseline subject $LOOM_SHA is not a commit in $LOOM; run scripts/baseline.sh"
jq -e '.typecheck == "clean" and (.total_tests | type == "number" and . > 0) and (.known_failures | type == "array")' \
  "$BASELINE" >/dev/null || fail "baseline is incomplete or its typecheck was dirty"

# BENCH_ARMS="ds41" (space/comma separated) verifies only the arms about to run.
# Historical arms may have left pi/models.json when their serving profile was
# retired; their recorded runs stay valid, but their catalog rows can no longer
# be re-verified against a live config.
selected_arms() {
  if [[ -n "${BENCH_ARMS:-}" ]]; then
    tr ' ,' '\n\n' <<<"$BENCH_ARMS" | sed '/^$/d'
  else
    benchmark_arm_ids
  fi
}

while IFS= read -r arm; do
  benchmark_arm_record "$arm" >/dev/null || fail "unknown arm in BENCH_ARMS: $arm"
  IFS=$'\t' read -r model served context profile _ label \
    <<<"$(benchmark_arm_record "$arm")"
  provider="${model%%/*}"
  selector="${model#*/}"
  model_id="${selector%%:*}"
  thinking_level="${selector##*:}"
  [[ "$served" == "$model_id" ]] \
    || fail "$arm serves $served but its Pi selector targets $model_id"
  [[ "$context" =~ ^[1-9][0-9]*$ ]] || fail "$arm has an invalid context window: $context"
  if [[ "$provider" == desktop-vllm ]]; then
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
  else
    [[ "$profile" == "cloud:$provider" ]] \
      || fail "$arm cloud profile '$profile' disagrees with selector provider '$provider'"
    expected_context="$((context / 1000))K"
    pi --list-models "$model_id" 2>/dev/null | awk \
      -v provider="$provider" -v model="$model_id" -v context="$expected_context" \
      '$1 == provider && $2 == model && $3 == context { found = 1 } END { exit !found }' \
      || fail "$arm ($label) is absent from Pi's provider catalog at context $expected_context"
    [[ "$thinking_level" =~ ^(off|minimal|low|medium|high|xhigh|max)$ ]] \
      || fail "$arm pins an unsupported thinking level: $thinking_level"
  fi
done < <(selected_arms)

# Local arms are measurable only if every child inherits the parent's exact
# selector. Routing rules match in order, so the first rule that can apply to a
# local parent (parentClass local or unconstrained) must be the plain
# inherit-the-parent rule; verify-run-models.sh then attests each child.
ROUTING="$ROOT/pi/model-routing.json"
# Every local arm depends on one rule: a local parent's children inherit its exact
# provider/model/thinking selector. Named per-arm targets were retired with the
# per-model rules; verify-run-models.sh still proves each child ran on the
# selector, so a routing regression voids the run instead of passing silently.
jq -e '
  [.rules[] | select(.when.parentClass == "local" or .when.parentClass == null)]
  | length > 0 and (.[0].when == {"parentClass": "local"}) and (.[0].use == {"kind": "parent"})
' "$ROUTING" >/dev/null || fail "Pi routing does not bind local children to the parent selector"

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

# Every protocol after v1 pins the Loom source its wire contract was frozen from.
for lock_version in v2 v3; do
  SOURCE_LOCK="$BENCH_DIR/protocols/$lock_version/source-lock.json"
  SOURCE_SHA="$(jq -er '.loom_base_sha' "$SOURCE_LOCK")" \
    || fail "$lock_version source lock has no Loom base SHA"
  while IFS=$'\t' read -r source_path expected_sha; do
    observed_sha="$(git -C "$LOOM" show "$SOURCE_SHA:$source_path" | sha256sum | cut -d' ' -f1)" \
      || fail "cannot read $lock_version locked source $source_path at $SOURCE_SHA"
    [[ "$observed_sha" == "$expected_sha" ]] \
      || fail "$lock_version source lock mismatch for $source_path: expected $expected_sha, observed $observed_sha"
  done < <(jq -r '.sources[] | [.path, .sha256] | @tsv' "$SOURCE_LOCK")
done

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
printf '  Arms: %s\n' "$(selected_arms | tr '\n' ' ')"
printf 'Run an authenticated online check with: bash scripts/run-arm.sh --probe <arm>\n'
