#!/usr/bin/env bash
# Assemble the GLM-5.3 v13 overlay archive: v12's overlay tree (legend
# r2.1 + the Spark TP2 port) plus the four ported files from the v13 staging,
# added as four new overlay entries. CPU-only: tar assembly + sha256 receipt.
# No Docker, no GPU, no serving impact — v11.1 stays served throughout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V12_DIR="$SCRIPT_DIR/glm53-v12-upstream-core-port"
V12_ARCHIVE="$V12_DIR/upstream-core-port-v12-pr710-pr718-pr694.tar.gz"
STAGING="$SCRIPT_DIR/staging/v13-pr52477-grammar-port/ported"
OUT_DIR="$SCRIPT_DIR/glm53-v13-grammar-port"
V13_ARCHIVE="$OUT_DIR/upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz"
RECEIPT="$OUT_DIR/assembly-receipt.txt"

# The four staged files and their overlay paths inside the archive. All four
# are replacements of base-image files (the base ships them; BASE-SHAS pins
# their image shas), so they are manifest replacements, not additions.
PORTED=(
  "v1/structured_output/__init__.py|upstream-g2/vllm/v1/structured_output/__init__.py"
  "v1/structured_output/utils.py|upstream-g2/vllm/v1/structured_output/utils.py"
  "v1/worker/gpu/structured_outputs.py|upstream-g2/vllm/v1/worker/gpu/structured_outputs.py"
  "v1/worker/gpu/warmup.py|upstream-g2/vllm/v1/worker/gpu/warmup.py"
)

for command in tar sha256sum; do
  command -v "$command" >/dev/null 2>&1 || { echo "error: $command is required" >&2; exit 1; }
done
[ -f "$V12_ARCHIVE" ] || { echo "error: v12 overlay archive missing: $V12_ARCHIVE" >&2; exit 1; }
[ -d "$STAGING" ] || { echo "error: v13 staging missing: $STAGING" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Extract v12's overlay tree (the archive root is upstream-core-port/).
tar -xzf "$V12_ARCHIVE" -C "$work"

# 2. Add the four ported files at their overlay paths.
for entry in "${PORTED[@]}"; do
  staged="${entry%%|*}"
  overlay="${entry##*|}"
  mkdir -p "$work/upstream-core-port/$(dirname "$overlay")"
  cp "$STAGING/$staged" "$work/upstream-core-port/$overlay"
done

# 3. Manifest gains exactly one line per ported file.
{
  for entry in "${PORTED[@]}"; do
    overlay="${entry##*|}"
    destination="/opt/infernal-invocation/vllm/vllm/v1/${overlay#upstream-g2/vllm/v1/}"
    printf '%s -> %s\n' "$overlay" "$destination"
  done
} >> "$work/upstream-core-port/MANIFEST.txt"

# 4. Tar the assembled overlay; the archive is the only engine code source.
mkdir -p "$OUT_DIR"
tar -czf "$V13_ARCHIVE" -C "$work" upstream-core-port
archive_sha256="$(sha256sum "$V13_ARCHIVE" | cut -d' ' -f1)"

# 5. Receipt with everything a local verifier needs to detect mangling.
file_count="$(tar -tzf "$V13_ARCHIVE" | grep -vc '/$')"
marker_count="$(grep -c 'PR53046-PORT' "$work/upstream-core-port/upstream-g2/vllm/v1/structured_output/__init__.py" | cut -d: -f2 || true)"
warmup_defer_count="$(grep -c 'PR55455-PORT' "$work/upstream-core-port/upstream-g2/vllm/v1/worker/gpu/warmup.py" || true)"
crash_design_count="$(grep -c '_build_grammar_row_mapping' "$work/upstream-core-port/upstream-g2/vllm/v1/worker/gpu/structured_outputs.py" || true)"
manifest_lines="$(tar -xzf "$V13_ARCHIVE" -O upstream-core-port/MANIFEST.txt | grep -vc '^$')"
{
  printf 'v13_overlay_archive=%s\n' "$V13_ARCHIVE"
  printf 'archive_sha256=%s\n' "$archive_sha256"
  printf 'file_count=%s\n' "$file_count"
  printf 'manifest_lines=%s\n' "$manifest_lines"
  printf 'pr53046_marker_count=%s\n' "$marker_count"
  printf 'pr55455_marker_count=%s\n' "$warmup_defer_count"
  printf 'crash_design_references=%s\n' "$crash_design_count"
  printf 'ported_files=%s\n' "${#PORTED[@]}"
} > "$RECEIPT"
chmod 600 "$RECEIPT"

printf 'v13 overlay assembled: %s\n' "$V13_ARCHIVE"
printf 'archive sha256: %s\n' "$archive_sha256"
printf 'receipt: %s\n' "$RECEIPT"
