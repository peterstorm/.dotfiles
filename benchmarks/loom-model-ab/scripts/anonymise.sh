#!/usr/bin/env bash
# Anonymise finished planning benchmark runs for blind grading.
#
#   bash scripts/anonymise.sh <batch-id> runs/<run-id> [runs/<run-id> ...]
#
# Copies each run's gradeable artifacts to blind/<batch-id>/arm-<LETTER>/ under
# a shuffled label, and writes the label→run mapping to a sibling file the
# grader is expected not to open until scoring is saved.
#
# Artifacts are scrubbed of the obvious tells: model ids, provider names, and
# container names appear in transcripts and sometimes in generated comments.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BENCH_DIR"

(($# >= 3)) || { echo "usage: $0 <batch-id> <run-dir> <run-dir> [...]" >&2; exit 2; }

BATCH="$1"; shift
OUT="blind/$BATCH"
MAP="blind/$BATCH.mapping.txt"

[[ -e "$OUT" || -e "$MAP" ]] && { echo "refusing to overwrite existing batch $BATCH" >&2; exit 1; }

for run in "$@"; do
  [[ -d "$run" ]] || { echo "not a run directory: $run" >&2; exit 1; }
done

mkdir -p "$OUT"
: > "$MAP"
chmod 600 "$MAP"

# Shuffle so label order carries no information about run order.
mapfile -t SHUFFLED < <(printf '%s\n' "$@" | shuf)

letter_for() { printf '%b' "\\$(printf '%03o' $((65 + $1)))"; }

# Tells that would unblind the grader if left in the artifacts.
scrub() {
  sed -E \
    -e 's/deepseek[-_ ]?v4[-_ ]?flash/MODEL-UNDER-TEST/gI' \
    -e 's/qwen ?3\.?8[-_ ]?27b/MODEL-UNDER-TEST/gI' \
    -e 's/glm[-_ ]?5\.?3[-_a-z0-9.]*/MODEL-UNDER-TEST/gI' \
    -e 's/glm53[-_a-z0-9.]*/MODEL-UNDER-TEST/gI' \
    -e 's/\bdeepseek\b/MODEL-UNDER-TEST/gI' \
    -e 's/\b(qwen|glm)\b/MODEL-UNDER-TEST/gI' \
    -e 's/\bds4\b/MODEL-UNDER-TEST/gI' \
    -e 's/\b(sglang|vllm|dspark|dflash2?|mtp3?)\b/BACKEND/gI' \
    -e 's/desktop-vllm[a-z0-9._\/-]*/PROVIDER/gI' \
    "$1"
}

for i in "${!SHUFFLED[@]}"; do
  run="${SHUFFLED[$i]}"
  label="arm-$(letter_for "$i")"
  dest="$OUT/$label"
  mkdir -p "$dest"

  for artifact in brainstorm.md spec.md interview.md plan.md plan-alignment.md task-graph.json discovery-checklist.tsv; do
    src="$run/$artifact"
    [[ -f "$src" ]] || continue
    scrub "$src" > "$dest/$artifact"
  done

  # Mechanical planning facts are gates too, but paths and model ids are tells.
  if [[ -f "$run/outcome.planning.json" ]]; then
    scrub "$run/outcome.planning.json" \
      | sed -E \
          -e 's/"(arm|run_id)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1": "REDACTED"/g' \
          -e 's#"worktree"[[:space:]]*:[[:space:]]*"[^"]*"#"worktree": "REDACTED"#g' \
      > "$dest/outcome.planning.json"
  fi

  printf '%s\t%s\n' "$label" "$run" >> "$MAP"
  echo "$label  <-  $run"
done

echo
echo "Blind artifacts: $OUT"
echo "Mapping:         $MAP  (do not open until scores are saved)"
echo
echo "Residual tells to check by eye before grading — the scrubber cannot catch them:"
echo "  * writing style and comment voice"
echo "  * timestamps inside diffs and transcripts"
echo "  * context-exhaustion artifacts that only one arm can produce"
