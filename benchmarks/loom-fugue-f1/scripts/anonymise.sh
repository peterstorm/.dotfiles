#!/usr/bin/env bash
# Create one blind batch from identity-compatible Fugue F1 planning runs.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=benchmarks/loom-fugue-f1/suite.sh
source "$BENCH_DIR/suite.sh"
cd "$BENCH_DIR"

(($# >= 3)) || { echo "usage: $0 <batch-id> <run-dir> <run-dir> [...]" >&2; exit 2; }
BATCH="$1"; shift
OUT="blind/$BATCH"
MAP="blind/$BATCH.mapping.txt"
[[ ! -e "$OUT" && ! -e "$MAP" ]] || { echo "refusing to overwrite batch: $BATCH" >&2; exit 1; }

EXPECTED_PROTOCOL="$(fugue_protocol_sha "$BENCH_DIR")"
EXPECTED_TARGET="$(fugue_source_lock_value "$BENCH_DIR" '.target.base_sha')"
EXPECTED_RUNTIME="$(fugue_source_lock_value "$BENCH_DIR" '.loom_runtime.base_sha')"
for run in "$@"; do
  [[ -r "$run/run.json" && -r "$run/outcome.planning.json" ]] || { echo "incomplete run: $run" >&2; exit 1; }
  jq -e \
    --arg suite "$FUGUE_SUITE_ID" \
    --arg version "$FUGUE_PROTOCOL_VERSION" \
    --arg protocol "$EXPECTED_PROTOCOL" \
    --arg target "$EXPECTED_TARGET" \
    --arg runtime "$EXPECTED_RUNTIME" '
      .suite_id == $suite and .protocol_version == $version and
      .protocol_sha256 == $protocol and .target.base_sha == $target and
      .loom_runtime_sha == $runtime
    ' "$run/run.json" >/dev/null || {
      echo "refusing mixed-suite/protocol/source blind batch: $run" >&2
      exit 1
    }
  jq -e '.planning_complete == true' "$run/outcome.planning.json" >/dev/null || {
    echo "semantic grading requires a mechanically complete run: $run" >&2
    exit 1
  }
done

mkdir -p "$OUT"
jq -n \
  --arg suite_id "$FUGUE_SUITE_ID" \
  --arg version "$FUGUE_PROTOCOL_VERSION" \
  --arg protocol "$EXPECTED_PROTOCOL" \
  --arg target "$EXPECTED_TARGET" \
  --arg runtime "$EXPECTED_RUNTIME" '
  {
    suite_id: $suite_id,
    protocol_version: $version,
    protocol_sha256: $protocol,
    target_base_sha: $target,
    loom_runtime_sha: $runtime
  }' > "$OUT/suite.json"
: > "$MAP"
chmod 600 "$MAP"
mapfile -t SHUFFLED < <(printf '%s\n' "$@" | shuf)
letter_for() { printf '%b' "\\$(printf '%03o' $((65 + $1)))"; }

scrub() {
  sed -E \
    -e 's/deepseek[-_ ]?v4[-_ ]?flash/MODEL-UNDER-TEST/gI' \
    -e 's/qwen ?3\.?8[-_ ]?flash[-_ ]?next[-_a-z0-9.]*/MODEL-UNDER-TEST/gI' \
    -e 's/qwen ?3\.?8[-_ ]?27b/MODEL-UNDER-TEST/gI' \
    -e 's/glm[-_ ]?5\.?3[-_a-z0-9.]*/MODEL-UNDER-TEST/gI' \
    -e 's/glm53[-_a-z0-9.]*/MODEL-UNDER-TEST/gI' \
    -e 's/\b(deepseek|qwen|glm|ds4)\b/MODEL-UNDER-TEST/gI' \
    -e 's/\b(sglang|vllm|dspark|dflash2?|mtp3?)\b/BACKEND/gI' \
    -e 's/desktop-vllm[a-z0-9._\/-]*/PROVIDER/gI' \
    "$1"
}

for index in "${!SHUFFLED[@]}"; do
  run="${SHUFFLED[$index]}"
  label="arm-$(letter_for "$index")"
  dest="$OUT/$label"
  mkdir -p "$dest"
  for artifact in brainstorm.md spec.md interview.md plan.md plan-alignment.md task-graph.json discovery-checklist.tsv; do
    [[ -f "$run/$artifact" ]] && scrub "$run/$artifact" > "$dest/$artifact"
  done
  scrub "$run/outcome.planning.json" \
    | sed -E \
      -e 's/"(arm|run_id)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1": "REDACTED"/g' \
      -e 's#"worktree"[[:space:]]*:[[:space:]]*"[^"]*"#"worktree": "REDACTED"#g' \
    > "$dest/outcome.planning.json"
  printf '%s\t%s\n' "$label" "$run" >> "$MAP"
  printf '%s <- %s\n' "$label" "$run"
done

echo "Blind artifacts: $OUT"
echo "Suite identity: $FUGUE_SUITE_ID / $EXPECTED_PROTOCOL / $EXPECTED_TARGET / $EXPECTED_RUNTIME"
echo "Mapping: $MAP (keep closed until scores are saved)"
