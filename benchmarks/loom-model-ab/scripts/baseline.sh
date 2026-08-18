#!/usr/bin/env bash
# Record what is ALREADY broken at the batch's base commit, once.
#
#   bash scripts/baseline.sh
#
# Loom's suite has a pre-existing failure (a pi-resources test that renames into
# a tmp cache). Without this record, every arm is charged with a regression it
# did not cause, and `regression.passed` measures the repository rather than the
# model. Every run in a batch shares one base commit, so this runs once — not
# once per arm.
#
# Re-run it whenever the Loom base commit moves. A baseline recorded against a
# different commit is worse than none, so the sha is stored and checked.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOM="${LOOM_REPO:-$HOME/dev/claude-plugins/loom}"
OUT="$BENCH_DIR/baseline"
mkdir -p "$OUT"

BASE_SHA="$(git -C "$LOOM" rev-parse HEAD)"
WORKTREE="$LOOM/../loom-baseline-$BASE_SHA"

cleanup() {
  git -C "$LOOM" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Base commit: $BASE_SHA"
git -C "$LOOM" worktree add --detach "$WORKTREE" "$BASE_SHA" >/dev/null
WORKTREE="$(cd "$WORKTREE" && pwd)"
[[ -e "$WORKTREE/node_modules" || ! -d "$LOOM/node_modules" ]] || \
  ln -s "$LOOM/node_modules" "$WORKTREE/node_modules"

echo "Typechecking..."
if (cd "$WORKTREE/engine" && env -u PI_CODING_AGENT timeout 600 bunx tsc --noEmit) \
    > "$OUT/typecheck.log" 2>&1; then
  TSC=clean
else
  TSC=dirty
fi
echo "  typecheck: $TSC"

echo "Running the full suite (this takes a few minutes)..."
(cd "$WORKTREE/engine" && env -u PI_CODING_AGENT timeout 1800 \
  bunx vitest run --testTimeout=15000 --reporter=json --outputFile="$OUT/suite.json") \
  > "$OUT/suite.log" 2>&1 || true

node -e '
  const fs = require("fs");
  const [src, dest, sha, tsc] = process.argv.slice(1);
  const r = JSON.parse(fs.readFileSync(src, "utf8"));
  const failures = [];
  for (const file of r.testResults ?? []) {
    for (const t of file.assertionResults ?? []) {
      if (t.status === "failed") failures.push(t.fullName ?? t.title);
    }
  }
  failures.sort();
  fs.writeFileSync(dest, `${JSON.stringify({
    base_sha: sha,
    typecheck: tsc,
    total_tests: r.numTotalTests ?? 0,
    known_failures: failures,
  }, null, 2)}\n`);
  console.log(`  ${r.numPassedTests ?? 0} passed, ${failures.length} known failure(s)`);
  for (const f of failures) console.log(`    - ${f}`);
' "$OUT/suite.json" "$OUT/known-failures.json" "$BASE_SHA" "$TSC"

echo
echo "Baseline written to $OUT/known-failures.json"
[[ "$TSC" == clean ]] || echo "WARNING: the base commit does not typecheck — fix before running arms." >&2
