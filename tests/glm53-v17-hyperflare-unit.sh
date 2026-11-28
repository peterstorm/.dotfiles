#!/usr/bin/env bash
# Unit test for the pure functions in scripts/inference/glm53/glm53-v17-hyperflare/pins.sh:
# the image-label check, the prefill modes, the export-log and receipt parsers.
# Sourcing defines values and functions only; nothing here touches Docker or a GPU.
# shellcheck disable=SC2034,SC2016 # out/status are read inside check's eval strings
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/inference/glm53/glm53-v17-hyperflare/pins.sh
source "$ROOT/scripts/inference/glm53/glm53-v17-hyperflare/pins.sh"

failures=0
cases=0
check() {
  cases=$((cases + 1))
  if ! eval "$2"; then
    failures=$((failures + 1))
    echo "FAIL $1" >&2
  fi
}

HFI="$V17_HYPERFLARE_INFERENCE_COMMIT" HFR="$V17_RECIPES_COMMIT" FI="$V17_FLASHINFER_COMMIT"
OTHER="0123456789abcdef0123456789abcdef01234567"

# --- image labels ----------------------------------------------------------------
check "the pinned labels match" 'v17_image_matches_pins "$HFI $HFR $FI" >/dev/null'
check "a match prints nothing" '[ -z "$(v17_image_matches_pins "$HFI $HFR $FI")" ]'
for slot in 1 2 3; do
  set -- "$HFI" "$HFR" "$FI"
  labels=("$@"); labels[slot - 1]="$OTHER"
  check "a different commit in slot $slot is refused" '! v17_image_matches_pins "${labels[*]}" >/dev/null'
  labels[slot - 1]=""
  check "a missing label in slot $slot is refused" '! v17_image_matches_pins "${labels[*]}" >/dev/null'
done
out="$(v17_image_matches_pins "$HFI $OTHER $FI")" || true
check "a mismatch names the source and both commits" '[[ "$out" == "hyperflare-recipes $OTHER, expected $HFR" ]]'
out="$(v17_image_matches_pins "")" || true
check "an unlabelled image names the first missing source" '[[ "$out" == "hyperflare-inference <none>, expected $HFI" ]]'
check "trailing label text is refused" '! v17_image_matches_pins "$HFI $HFR $FI extra" >/dev/null'
check "the inspect format names the three label keys in order" \
  '[ "$(v17_image_labels_format)" = "{{index .Config.Labels \"$V17_LABEL_HFI\"}} {{index .Config.Labels \"$V17_LABEL_HFR\"}} {{index .Config.Labels \"$V17_LABEL_FI\"}}" ]'
check "the image tag names all three sources" \
  '[[ "$V17_IMAGE" == *"hfi${HFI:0:8}"*"hfr${HFR:0:8}"*"fi${FI:0:8}"* ]]'
for pin in "$HFI" "$HFR" "$FI"; do
  check "pin $pin is a full commit id" '[[ "$pin" =~ ^[0-9a-f]{40}$ ]]'
done

# --- prefill modes ----------------------------------------------------------------
check "the modes are rowshard and baseline" '[ "${V17_PREFILL_MODES[*]}" = "rowshard baseline" ]'
check "rowshard exports 12288-token chunks" '[ "$(v17_prefill_chunk rowshard)" = 12288 ]'
check "baseline exports upstream's 4096-token chunks" '[ "$(v17_prefill_chunk baseline)" = 4096 ]'
check "rowshard adds both row-shard flags" \
  '[ "$(v17_prefill_flags rowshard | paste -sd" ")" = "--row-shard-prefill --row-shard-attention" ]'
check "baseline adds no flags" '[ -z "$(v17_prefill_flags baseline)" ]'
check "rowshard chunks reach PR #55's PCIe row-sharded attention threshold" '(( $(v17_prefill_chunk rowshard) >= V17_ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE ))'
check "the PCIe threshold is PR #55's 12288" '[ "$V17_ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE" = 12288 ]'
check "rowshard chunks fit the quarter-MLP prefill shape at TP2" '(( $(v17_prefill_chunk rowshard) % (4 * 128 * 2) == 0 ))'
for bogus in "" ROWSHARD row-shard v16 "rowshard " ../rowshard; do
  check "unknown mode '$bogus' has no chunk" '! v17_prefill_chunk "$bogus" >/dev/null 2>&1'
  check "unknown mode '$bogus' has no flags" '! v17_prefill_flags "$bogus" >/dev/null 2>&1'
  status=0; out="$(v17_resolve_prefill "$bogus" 2>&1 >/dev/null)" || status=$?
  check "resolve refuses '$bogus' with status 2" '[ "$status" = 2 ]'
  check "resolve names the known modes for '$bogus'" '[[ "$out" == *"known: rowshard baseline"* ]]'
done
for mode in "${V17_PREFILL_MODES[@]}"; do
  check "resolve returns known mode $mode" '[ "$(v17_resolve_prefill "$mode")" = "$mode" ]'
done

# --- export log ------------------------------------------------------------------
log=$'Graph catalog: 56 graphs\nExported cache entry: /flare-home/.cache/flare/cores/models/glm53-fp4-local/gb202-tp2-202611281200'
check "the entry is read from the export log" \
  '[ "$(v17_entry_from_export_log glm53-fp4-local <<<"$log")" = /flare-home/.cache/flare/cores/models/glm53-fp4-local/gb202-tp2-202611281200 ]'
two=$'Exported cache entry: /flare-home/c/glm53-fp4-local/old\nnoise\nExported cache entry: /flare-home/c/glm53-fp4-local/new/'
check "the last entry wins and a trailing slash is dropped" \
  '[ "$(v17_entry_from_export_log glm53-fp4-local <<<"$two")" = /flare-home/c/glm53-fp4-local/new ]'
check "a log without an entry line fails" '! v17_entry_from_export_log glm53-fp4-local <<<"Graph catalog: 56 graphs" >/dev/null'
check "an entry for another model fails" \
  '! v17_entry_from_export_log glm53-fp4-local <<<"Exported cache entry: /flare-home/c/glm53-uncensored/v1" >/dev/null'
check "a version with a path separator fails" \
  '! v17_entry_from_export_log glm53-fp4-local <<<"Exported cache entry: /flare-home/c/glm53-fp4-local/a b" >/dev/null'
check "a relative entry fails" '! v17_entry_from_export_log glm53-fp4-local <<<"Exported cache entry: c/glm53-fp4-local/v1" >/dev/null'
check "an entry names its MODEL@VERSION core" \
  '[ "$(v17_core_of_entry /flare-home/.cache/flare/cores/models/glm53-fp4-local/gb202-tp2-1)" = glm53-fp4-local@gb202-tp2-1 ]'

# --- receipt ---------------------------------------------------------------------
receipt=$'model=glm53-fp4-local\ncore=glm53-fp4-local@gb202-tp2-1\nprefill=rowshard\nchunk=12288'
check "a receipt yields its core" '[ "$(v17_receipt_core glm53-fp4-local rowshard <<<"$receipt")" = glm53-fp4-local@gb202-tp2-1 ]'
out="$(v17_receipt_core glm53-fp4-local baseline <<<"$receipt")" || true
check "a receipt for the other mode is refused" '[ "$out" = "the receipt is for prefill '"'"'rowshard'"'"', expected baseline" ]'
check "a receipt for another model is refused" \
  '! v17_receipt_core glm53-fp4-local rowshard <<<"${receipt/core=glm53-fp4-local/core=glm53-uncensored}" >/dev/null'
check "a receipt naming two cores is refused" \
  '! v17_receipt_core glm53-fp4-local rowshard <<<"$receipt"$'"'"'\ncore=glm53-fp4-local@x'"'"' >/dev/null'
check "a receipt without a core is refused" \
  '! v17_receipt_core glm53-fp4-local rowshard <<<"prefill=rowshard" >/dev/null'
check "a receipt without a prefill line is refused" \
  '! v17_receipt_core glm53-fp4-local rowshard <<<"core=glm53-fp4-local@v" >/dev/null'
check "a core version with a slash is refused" \
  '! v17_receipt_core glm53-fp4-local rowshard <<<"${receipt/@gb202-tp2-1/@a/b}" >/dev/null'

if [ "$failures" -ne 0 ]; then
  echo "glm53-v17-hyperflare unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "glm53-v17-hyperflare unit: PASS ($cases checks)"
