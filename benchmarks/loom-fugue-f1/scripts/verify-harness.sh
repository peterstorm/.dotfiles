#!/usr/bin/env bash
# Fail-closed admission check for the Fugue F1 planning benchmark.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(git -C "$BENCH_DIR" rev-parse --show-toplevel)"
FUGUE="${FUGUE_REPO:-$HOME/dev/agentic/fugue}"
LOOM_RUNTIME="${LOOM_RUNTIME_REPO:-$HOME/dev/claude-plugins/loom-benchmark-runtime-3815f65}"
# shellcheck source=benchmarks/loom-fugue-f1/suite.sh
source "$BENCH_DIR/suite.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
for command in bun git jq node pi sha256sum; do command -v "$command" >/dev/null || fail "missing command: $command"; done

required=(README.md operator-rpc.md suite.sh source-lock.json frozen/brief.md frozen/answer-key.md hidden/reference-spec.md hidden/acceptance-scenarios.md rubric.md)
mapfile -t protocol_files < <(fugue_protocol_files)
[[ "${protocol_files[*]}" == 'source-lock.json frozen/brief.md frozen/answer-key.md hidden/reference-spec.md hidden/acceptance-scenarios.md rubric.md' ]] \
  || fail 'protocol artifact catalog changed unexpectedly'
for file in "${required[@]}" "${protocol_files[@]}"; do [[ -r "$BENCH_DIR/$file" ]] || fail "unreadable artifact: $file"; done

jq -e --arg suite "$FUGUE_SUITE_ID" --arg version "$FUGUE_PROTOCOL_VERSION" '
  .suite_id == $suite and .protocol_version == $version and
  .target.repository == "https://github.com/peterstorm/fugue.git" and
  (.target.base_sha | test("^[0-9a-f]{40}$")) and
  (.loom_runtime.base_sha | test("^[0-9a-f]{40}$")) and
  .pi.version == "0.83.0" and (.sources | length >= 6)
' "$BENCH_DIR/source-lock.json" >/dev/null || fail 'malformed source lock'

TARGET_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.target.base_sha')"
RUNTIME_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.loom_runtime.base_sha')"
[[ "$(git -C "$FUGUE" rev-parse "$TARGET_SHA^{commit}")" == "$TARGET_SHA" ]] || fail 'target commit unavailable'
[[ "$(git -C "$LOOM_RUNTIME" rev-parse HEAD)" == "$RUNTIME_SHA" ]] || fail 'Loom runtime checkout mismatch'
[[ "$(pi --version)" == "$(fugue_source_lock_value "$BENCH_DIR" '.pi.version')" ]] || fail 'Pi version mismatch'
bash "$BENCH_DIR/scripts/isolation.sh" status >/dev/null || fail 'benchmark isolation is inactive'

while IFS=$'\t' read -r path expected; do
  observed="$(git -C "$FUGUE" show "$TARGET_SHA:$path" | sha256sum | cut -d' ' -f1)" \
    || fail "cannot read locked target source: $path"
  [[ "$observed" == "$expected" ]] || fail "source lock mismatch: $path"
done < <(jq -r '.sources[] | [.path, .sha256] | @tsv' "$BENCH_DIR/source-lock.json")

BASELINE="$BENCH_DIR/baseline/receipt.json"
[[ -r "$BASELINE" ]] || fail 'baseline receipt missing; run scripts/baseline.sh'
jq -e \
  --arg suite "$FUGUE_SUITE_ID" --arg target "$TARGET_SHA" --arg runtime "$RUNTIME_SHA" '
  .suite_id == $suite and .target_base_sha == $target and .loom_runtime_sha == $runtime and
  .typecheck == "clean" and .tests == "clean" and .total_tests > 0
' "$BASELINE" >/dev/null || fail 'baseline receipt is stale or dirty'

reference_frs="$(mktemp)"
scenario_frs="$(mktemp)"
trap 'rm -f "$reference_frs" "$scenario_frs"' EXIT
grep -oE '^- \*\*FR-[0-9]+' "$BENCH_DIR/hidden/reference-spec.md" | grep -oE 'FR-[0-9]+' | sort -u > "$reference_frs"
grep -oE '\[FR-[0-9]+\]' "$BENCH_DIR/hidden/acceptance-scenarios.md" | tr -d '[]' | sort -u > "$scenario_frs"
cmp -s "$reference_frs" "$scenario_frs" || {
  diff -u "$reference_frs" "$scenario_frs" >&2 || true
  fail 'reference requirements and acceptance scenarios cover different FR sets'
}
[[ "$(wc -l < "$reference_frs")" -eq 40 ]] || fail 'reference must contain exactly 40 unique requirements'
for number in $(seq -w 001 040); do grep -Fxq "FR-$number" "$reference_frs" || fail "missing FR-$number"; done
[[ "$(grep -cE '^- \*\*AS-[0-9]+' "$BENCH_DIR/hidden/acceptance-scenarios.md")" -eq 25 ]] || fail 'expected 25 acceptance scenarios'

PROTOCOL_SHA="$(fugue_protocol_sha "$BENCH_DIR")"
[[ "$PROTOCOL_SHA" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid protocol SHA'
grep -Fq 'Do not implement anything.' "$BENCH_DIR/frozen/brief.md" || fail 'brief lost planning-only boundary'
grep -Fq 'Every supported checkpointer must agree' "$BENCH_DIR/frozen/answer-key.md" || fail 'answer key lost adapter parity decision'
grep -Fq 'not comparable with the UI-relay benchmark.' "$BENCH_DIR/rubric.md" || fail 'rubric lost comparison boundary'
! rg -n 'tmux|send-keys' "$BENCH_DIR/scripts" --glob '!verify-harness.sh' >/dev/null || fail 'RPC benchmark scripts retain tmux control'

for script in suite.sh scripts/isolation.sh scripts/baseline.sh scripts/run-arm.sh scripts/verify-child-outputs.sh scripts/grade-planning.sh scripts/anonymise.sh scripts/verify-harness.sh; do
  [[ -x "$BENCH_DIR/$script" ]] || fail "script is not executable: $script"
  bash -n "$BENCH_DIR/$script" || fail "shell syntax failed: $script"
done
bash "$ROOT/tests/loom-fugue-f1-contract.sh" --self-check >/dev/null || fail 'benchmark contract self-check failed'

printf 'PASS: Fugue F1 benchmark is internally consistent\n'
printf '  Suite:    %s\n' "$FUGUE_SUITE_ID"
printf '  Protocol: %s\n' "$PROTOCOL_SHA"
printf '  Target:   %s\n' "$TARGET_SHA"
printf '  Runtime:  %s\n' "$RUNTIME_SHA"
