#!/usr/bin/env bash
# Qualify the pinned target and already-qualified Loom runtime before a batch.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(git -C "$BENCH_DIR" rev-parse --show-toplevel)"
FUGUE="${FUGUE_REPO:-$HOME/dev/agentic/fugue}"
LOOM_RUNTIME="${LOOM_RUNTIME_REPO:-$HOME/dev/claude-plugins/loom-benchmark-runtime-3815f65}"
# shellcheck source=benchmarks/loom-fugue-f1/suite.sh
source "$BENCH_DIR/suite.sh"

TARGET_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.target.base_sha')"
RUNTIME_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.loom_runtime.base_sha')"
PI_VERSION="$(fugue_source_lock_value "$BENCH_DIR" '.pi.version')"
OBSERVED_PI="$(pi --version)"
[[ "$OBSERVED_PI" == "$PI_VERSION" ]] || { echo "Pi version mismatch: $OBSERVED_PI != $PI_VERSION" >&2; exit 1; }
[[ "$(git -C "$FUGUE" rev-parse "$TARGET_SHA^{commit}")" == "$TARGET_SHA" ]] || { echo 'missing pinned Fugue commit' >&2; exit 1; }
[[ "$(git -C "$LOOM_RUNTIME" rev-parse HEAD)" == "$RUNTIME_SHA" ]] || { echo 'Loom runtime checkout is not pinned' >&2; exit 1; }

RUNTIME_BASELINE="$ROOT/benchmarks/loom-model-ab/baseline/known-failures.json"
jq -e --arg sha "$RUNTIME_SHA" '.base_sha == $sha and .typecheck == "clean" and .total_tests > 0' \
  "$RUNTIME_BASELINE" >/dev/null || { echo 'qualified Loom runtime baseline is missing or stale' >&2; exit 1; }

mkdir -p "$BENCH_DIR/baseline"
TYPECHECK_LOG="$BENCH_DIR/baseline/typecheck.log"
TEST_LOG="$BENCH_DIR/baseline/framework-tests.log"
BASELINE_TMP="$(mktemp -d)"
BASELINE_WORKTREE="$BASELINE_TMP/worktree"
cleanup() {
  git -C "$FUGUE" worktree remove --force "$BASELINE_WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$BASELINE_TMP"
}
trap cleanup EXIT
git -C "$FUGUE" worktree add --detach "$BASELINE_WORKTREE" "$TARGET_SHA" >/dev/null
if [[ -d "$FUGUE/node_modules" ]]; then ln -s "$FUGUE/node_modules" "$BASELINE_WORKTREE/node_modules"; fi
if [[ -d "$FUGUE/packages/framework/node_modules" ]]; then
  ln -s "$FUGUE/packages/framework/node_modules" "$BASELINE_WORKTREE/packages/framework/node_modules"
fi
(cd "$BASELINE_WORKTREE" && bun run --filter @fuguejs/framework typecheck) >"$TYPECHECK_LOG" 2>&1
(cd "$BASELINE_WORKTREE" && bun run --filter @fuguejs/framework test) >"$TEST_LOG" 2>&1
TESTS="$(grep -Eo '[0-9]+ pass' "$TEST_LOG" | tail -1 | awk '{print $1}')"
[[ "$TESTS" =~ ^[1-9][0-9]*$ ]] || { echo 'could not parse passing test count' >&2; exit 1; }

jq -n \
  --arg suite_id "$FUGUE_SUITE_ID" \
  --arg target_base_sha "$TARGET_SHA" \
  --arg loom_runtime_sha "$RUNTIME_SHA" \
  --arg pi_version "$PI_VERSION" \
  --argjson total_tests "$TESTS" \
  --arg created_at "$(date -Is)" \
  '{
    suite_id: $suite_id,
    target_base_sha: $target_base_sha,
    loom_runtime_sha: $loom_runtime_sha,
    pi_version: $pi_version,
    typecheck: "clean",
    tests: "clean",
    total_tests: $total_tests,
    created_at: $created_at
  }' > "$BENCH_DIR/baseline/receipt.json"
cat "$BENCH_DIR/baseline/receipt.json"
