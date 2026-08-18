#!/usr/bin/env bash
# Mechanically grade one finished benchmark arm.
#
#   bash scripts/grade-implementation.sh <worktree> <run-dir>
#
# Everything here is engine-produced evidence: no model judges any of it, so
# none of it needs a trust model. The blind rubric is scored separately and
# must never overturn these facts.
#
# Outcomes are recorded as ORTHOGONAL facts. A step's exit code, whether it
# timed out, and whether it was killed by a signal are three independent
# values, and a step counts as satisfied only on their conjunction. A process
# can trap SIGTERM and exit 0; an exit code read alone would certify a killed
# suite as a passing one, and a gate that confidently certifies something false
# is worse than no gate.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(($# == 2)) || { echo "usage: $0 <worktree> <run-dir>" >&2; exit 2; }
WORKTREE="$(cd "$1" && pwd)"
mkdir -p "$2"
RUN_DIR="$(cd "$2" && pwd)"

# The baseline is the frozen-types commit written by run-arm.sh — everything
# after it is the model's work. Guessing it (HEAD@{1}, merge-base) silently
# produces the wrong diff when a run is re-graded, so it is required.
[[ -f "$RUN_DIR/base_sha" ]] || {
  echo "missing $RUN_DIR/base_sha — created by run-arm.sh; refusing to guess the baseline" >&2
  exit 1
}
BASE_SHA="$(<"$RUN_DIR/base_sha")"

STEP_TIMEOUT="${STEP_TIMEOUT:-600}"
IMPL="engine/src/core/ui-relay.ts"
TYPES="engine/src/core/ui-relay-types.ts"
HIDDEN_SRC="$BENCH_DIR/hidden/ui-relay.hidden.test.ts"
HIDDEN_DEST="$WORKTREE/engine/tests/core/ui-relay.hidden.test.ts"

# Loom's suite lives in engine/ and unsets PI_CODING_AGENT — an inherited value
# changes what the harness resources resolve to and would make the grade a
# property of the grader's shell rather than of the run.
ENGINE="$WORKTREE/engine"

log() { printf '\n=== %s\n' "$*"; }

# --- step runner: exit code, timeout, and signal captured separately --------

STEP_EXIT=0 STEP_TIMED_OUT=false STEP_SIGNAL=null STEP_LOG=""

# run_step <name> <command-string>
# The command runs in engine/ with PI_CODING_AGENT unset. `timeout` cannot
# invoke a shell function, so the command is executed through bash -c.
run_step() {
  local name="$1" command="$2"
  STEP_LOG="$RUN_DIR/logs/$name.log"
  mkdir -p "$(dirname "$STEP_LOG")"
  STEP_TIMED_OUT=false
  STEP_SIGNAL=null

  set +e
  timeout --signal=TERM --kill-after=30s "$STEP_TIMEOUT" \
    env -u PI_CODING_AGENT bash -c "cd \"\$0\" && $command" "$ENGINE" \
    >"$STEP_LOG" 2>&1
  STEP_EXIT=$?
  set -e

  # 124 is timeout's own verdict; >128 means the child died on a signal. Both
  # can coexist with a misleading exit code, so both are recorded regardless.
  if ((STEP_EXIT == 124 || STEP_EXIT == 137)); then STEP_TIMED_OUT=true; fi
  if ((STEP_EXIT > 128)); then STEP_SIGNAL=$((STEP_EXIT - 128)); fi

  printf '%s: exit=%s timed_out=%s signal=%s\n' "$name" "$STEP_EXIT" "$STEP_TIMED_OUT" "$STEP_SIGNAL"
}

# A step is satisfied only if it exited 0 AND did not time out AND was not signalled.
step_ok() { [[ "$STEP_EXIT" == 0 && "$STEP_TIMED_OUT" == false && "$STEP_SIGNAL" == null ]] && echo true || echo false; }

json_bool() { [[ "$1" == true ]] && echo true || echo false; }

# --- 1. protocol integrity ---------------------------------------------------

log "Protocol integrity"

FROZEN_INTACT=false
if cmp -s "$BENCH_DIR/frozen/ui-relay-types.ts" "$WORKTREE/$TYPES"; then
  FROZEN_INTACT=true
else
  echo "VIOLATION: frozen types file was modified"
  diff -u "$BENCH_DIR/frozen/ui-relay-types.ts" "$WORKTREE/$TYPES" \
    > "$RUN_DIR/frozen-file.diff" || true
fi

# Scope: which tracked files changed since the benchmark base commit?
git -C "$WORKTREE" add -A >/dev/null 2>&1 || true
mapfile -t CHANGED < <(git -C "$WORKTREE" diff --cached --name-only "$BASE_SHA" -- || true)
printf '%s\n' "${CHANGED[@]}" > "$RUN_DIR/changed-files.txt"

SCOPE_RESPECTED=true
for f in "${CHANGED[@]}"; do
  [[ -z "$f" ]] && continue
  case "$f" in
    # node_modules is the harness's own symlink, not the arm's work.
    engine/src/core/ui-relay.ts|engine/tests/**|engine/src/core/ui-relay-types.ts|.claude/specs/*|node_modules) ;;
    *) echo "out-of-scope change: $f"; SCOPE_RESPECTED=false ;;
  esac
done

IMPL_EXISTS=false
[[ -f "$WORKTREE/$IMPL" ]] && IMPL_EXISTS=true
IMPL_LOC=0
$IMPL_EXISTS && IMPL_LOC=$(grep -cve '^\s*$' "$WORKTREE/$IMPL" || true)

git -C "$WORKTREE" diff --cached "$BASE_SHA" > "$RUN_DIR/diff.patch" || true

# --- 2. typecheck ------------------------------------------------------------

log "Typecheck"

# Was the worktree already broken before the model touched it? Without this,
# "typecheck_clean: false" is ambiguous between a defect and a bad baseline.
BASELINE_TSC_CLEAN=false
if [[ -f "$RUN_DIR/baseline-typecheck.log" ]]; then
  [[ -s "$RUN_DIR/baseline-typecheck.log" ]] || BASELINE_TSC_CLEAN=true
else
  echo "no baseline-typecheck.log — treating baseline as unknown/dirty"
fi

run_step typecheck 'bunx tsc --noEmit'
TYPECHECK_CLEAN="$(step_ok)"
TYPECHECK_EXIT=$STEP_EXIT TYPECHECK_TIMEOUT=$STEP_TIMED_OUT TYPECHECK_SIGNAL=$STEP_SIGNAL

# `any` and non-null assertions are a stated NFR, so they are counted, not judged.
ANY_COUNT=0
$IMPL_EXISTS && ANY_COUNT=$(grep -Eco '(:|<)\s*any\b|\bas any\b' "$WORKTREE/$IMPL" || true)

# --- 3. the arm's own suite --------------------------------------------------

log "Arm's own test suite"

# The arm's tests are the test files IT added or changed — derived from the
# diff, not guessed from a filename convention. Running Loom's whole suite here
# would conflate "this arm's tests pass" with "500 pre-existing tests pass",
# and a slow or flaky unrelated test would then read as an arm failure.
OWN_TEST_FILES=()
for f in "${CHANGED[@]}"; do
  [[ "$f" == engine/tests/*.test.ts ]] && OWN_TEST_FILES+=("${f#engine/}")
done

OWN_TESTS_PASS=false
OWN_TEST_COUNT=0
OWN_TEST_FILE_COUNT=${#OWN_TEST_FILES[@]}

if ((OWN_TEST_FILE_COUNT == 0)); then
  echo "the arm added no test file — own_tests cannot pass"
else
  printf '%s\n' "${OWN_TEST_FILES[@]}"
  run_step own-tests "bunx vitest run ${OWN_TEST_FILES[*]} --testTimeout=15000 --reporter=json --outputFile='$RUN_DIR/own-tests.json'"
  OWN_TESTS_PASS="$(step_ok)"
  if [[ -f "$RUN_DIR/own-tests.json" ]]; then
    OWN_TEST_COUNT=$(node -e '
      const r = require(process.argv[1]);
      console.log(r.numTotalTests ?? 0);
    ' "$RUN_DIR/own-tests.json" 2>/dev/null || echo 0)
  fi
fi

# Did the arm break anything else? Separate fact, separate budget — Loom's full
# suite is minutes long, so it gets its own timeout and never gates the above.
log "Regression: Loom's pre-existing suite"
STEP_TIMEOUT_SAVED="$STEP_TIMEOUT"; STEP_TIMEOUT="${REGRESSION_TIMEOUT:-1800}"
run_step regression "bunx vitest run --testTimeout=15000 --reporter=json --outputFile='$RUN_DIR/regression.json'"
REGRESSION_EXIT=$STEP_EXIT REGRESSION_TIMEOUT_HIT=$STEP_TIMED_OUT
STEP_TIMEOUT="$STEP_TIMEOUT_SAVED"

# The suite already fails at the base commit. Charging that to the arm would
# make this field a property of the repository, not of the model, so only
# failures absent from the recorded baseline count.
BASELINE_FILE="$BENCH_DIR/baseline/known-failures.json"
REGRESSION_NEW=null
REGRESSION_PASS=false
if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "no baseline at $BASELINE_FILE — run scripts/baseline.sh; new-failure count unavailable"
elif [[ -f "$RUN_DIR/regression.json" ]]; then
  BASELINE_SHA="$(node -e 'console.log(require(process.argv[1]).base_sha ?? "")' "$BASELINE_FILE")"
  LOOM_BASE="$(git -C "$WORKTREE" rev-parse "$BASE_SHA^" 2>/dev/null || echo "")"
  if [[ -n "$BASELINE_SHA" && "$BASELINE_SHA" != "$LOOM_BASE" ]]; then
    echo "WARNING: baseline is for $BASELINE_SHA but this run is off $LOOM_BASE — re-run scripts/baseline.sh"
  fi
  REGRESSION_NEW=$(node -e '
    const fs = require("fs");
    const [runFile, baseFile] = process.argv.slice(1);
    const known = new Set(JSON.parse(fs.readFileSync(baseFile, "utf8")).known_failures ?? []);
    const r = JSON.parse(fs.readFileSync(runFile, "utf8"));
    const fresh = [];
    for (const file of r.testResults ?? []) {
      for (const t of file.assertionResults ?? []) {
        const name = t.fullName ?? t.title;
        if (t.status === "failed" && !known.has(name)) fresh.push(name);
      }
    }
    console.error(fresh.map((f) => `  new failure: ${f}`).join("\n"));
    console.log(fresh.length);
  ' "$RUN_DIR/regression.json" "$BASELINE_FILE" 2>&1 | tail -1)
  [[ "$REGRESSION_NEW" == 0 ]] && REGRESSION_PASS=true
  echo "new failures beyond baseline: $REGRESSION_NEW"
fi

# --- 4. hidden acceptance suite ----------------------------------------------

log "Hidden acceptance suite"
mkdir -p "$(dirname "$HIDDEN_DEST")"
cp "$HIDDEN_SRC" "$HIDDEN_DEST"
# Remove it however this script exits — a hidden suite left in a worktree that
# is later reused would silently contaminate the next run.
trap 'rm -f "$HIDDEN_DEST"' EXIT

run_step hidden-tests "bunx vitest run tests/core/ui-relay.hidden.test.ts --testTimeout=15000 --reporter=json --outputFile='$RUN_DIR/hidden-tests.json'"
HIDDEN_RAN="$(step_ok)"

HIDDEN_PASSED=0 HIDDEN_FAILED=0
if [[ -f "$RUN_DIR/hidden-tests.json" ]]; then
  read -r HIDDEN_PASSED HIDDEN_FAILED < <(node -e '
    const r = require(process.argv[1]);
    console.log(`${r.numPassedTests ?? 0} ${r.numFailedTests ?? 0}`);
  ' "$RUN_DIR/hidden-tests.json" 2>/dev/null || echo "0 0")

  # Per-requirement results: every hidden test names its FR in the title.
  node -e '
    const r = require(process.argv[1]);
    const rows = [];
    for (const file of r.testResults ?? []) {
      for (const t of file.assertionResults ?? []) {
        const fr = (t.fullName ?? t.title ?? "").match(/FR-\d+/)?.[0] ?? "UNTAGGED";
        rows.push({ fr, title: t.title, status: t.status });
      }
    }
    rows.sort((a, b) => a.fr.localeCompare(b.fr));
    console.log(JSON.stringify(rows, null, 2));
  ' "$RUN_DIR/hidden-tests.json" > "$RUN_DIR/hidden-by-requirement.json" 2>/dev/null || true
fi

rm -f "$HIDDEN_DEST"
trap - EXIT

# --- 5. mutation score on the arm's own tests --------------------------------
#
# Both arms write their own tests, and "tests pass" is gameable by writing
# vacuous ones. Mutation score separates a suite that proves something from a
# suite that only reads well. If the tooling is absent the score is null with a
# stated reason — never 0, which would read as "the tests caught nothing".

log "Mutation score"
MUTATION_SCORE=null
MUTATION_SKIPPED_REASON=null
if [[ ! -x "$ENGINE/node_modules/.bin/stryker" ]]; then
  MUTATION_SKIPPED_REASON='"stryker not installed in engine/"'
  echo "skipped: stryker not installed (npm i -D @stryker-mutator/core @stryker-mutator/vitest-runner in engine/)"
else
  cat > "$ENGINE/stryker.bench.json" <<'JSON'
{
  "packageManager": "npm",
  "testRunner": "vitest",
  "mutate": ["src/core/ui-relay.ts"],
  "reporters": ["json"],
  "jsonReporter": { "fileName": "reports/mutation/bench.json" },
  "coverageAnalysis": "perTest"
}
JSON
  run_step mutation './node_modules/.bin/stryker run stryker.bench.json'
  if [[ -f "$ENGINE/reports/mutation/bench.json" ]]; then
    MUTATION_SCORE=$(node -e '
      const r = require(process.argv[1]);
      let killed = 0, total = 0;
      for (const f of Object.values(r.files ?? {})) {
        for (const m of f.mutants ?? []) {
          if (m.status === "Ignored" || m.status === "CompileError") continue;
          total++;
          if (m.status === "Killed" || m.status === "Timeout") killed++;
        }
      }
      console.log(total ? (killed / total).toFixed(3) : "null");
    ' "$ENGINE/reports/mutation/bench.json" 2>/dev/null || echo null)
    cp "$ENGINE/reports/mutation/bench.json" "$RUN_DIR/mutation.json" 2>/dev/null || true
  else
    MUTATION_SKIPPED_REASON='"stryker produced no report"'
  fi
  rm -f "$ENGINE/stryker.bench.json"
fi

# --- 6. outcome facts --------------------------------------------------------

cat > "$RUN_DIR/outcome.mechanical.json" <<JSON
{
  "worktree": "$WORKTREE",
  "base_sha": "$BASE_SHA",
  "protocol": {
    "frozen_file_intact": $(json_bool "$FROZEN_INTACT"),
    "scope_respected": $(json_bool "$SCOPE_RESPECTED"),
    "implementation_exists": $(json_bool "$IMPL_EXISTS"),
    "implementation_loc": $IMPL_LOC,
    "any_occurrences": $ANY_COUNT
  },
  "typecheck": {
    "baseline_was_clean": $BASELINE_TSC_CLEAN,
    "clean": $TYPECHECK_CLEAN,
    "exit_code": $TYPECHECK_EXIT,
    "timed_out": $TYPECHECK_TIMEOUT,
    "signal": $TYPECHECK_SIGNAL
  },
  "own_tests": {
    "passed": $OWN_TESTS_PASS,
    "count": $OWN_TEST_COUNT,
    "test_files": $OWN_TEST_FILE_COUNT
  },
  "regression": {
    "no_new_failures": $REGRESSION_PASS,
    "new_failures": $REGRESSION_NEW,
    "exit_code": $REGRESSION_EXIT,
    "timed_out": $REGRESSION_TIMEOUT_HIT
  },
  "hidden_suite": {
    "executed": $HIDDEN_RAN,
    "passed": $HIDDEN_PASSED,
    "failed": $HIDDEN_FAILED,
    "by_requirement": "hidden-by-requirement.json"
  },
  "mutation": {
    "score": $MUTATION_SCORE,
    "skipped_reason": $MUTATION_SKIPPED_REASON
  }
}
JSON

log "Result"
cat "$RUN_DIR/outcome.mechanical.json"

echo
echo "Not measured here, and still required before this arm is graded:"
echo "  * requirement DISCOVERY — did its own spec.md name each FR? (hidden/reference-spec.md)"
echo "  * the blind rubric (rubric.md), scored from anonymised artifacts"
echo "  * wave-gate outcome, context exhaustion, looping, and give-up — from the run log"
