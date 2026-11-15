#!/usr/bin/env bash
# Unit test for scripts/inference/glm53/hyperflare-variants.sh: the one table that
# says which checkpoint directory, container, served id and provenance each
# Hyperflare GLM-5.3 variant has. Pure (sourcing defines functions only).
# shellcheck disable=SC2034 # seen/err/status are read inside check's eval strings
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/inference/glm53/hyperflare-variants.sh
source "$ROOT/scripts/inference/glm53/hyperflare-variants.sh"

failures=0
cases=0
check() {
  cases=$((cases + 1))
  if ! eval "$2"; then
    failures=$((failures + 1))
    echo "FAIL $1" >&2
  fi
}

# The shipped variants and their exact names: these are the strings the receipts,
# containers, Pi's catalog and switch-primary.sh already carry.
check "variants are v16 and uncensored" '[ "${HYPERFLARE_VARIANTS[*]}" = "v16 uncensored" ]'
check "v16 model" '[ "$(hyperflare_variant_model v16)" = glm53-fp4-local ]'
check "v16 container" '[ "$(hyperflare_variant_container v16)" = glm53-flash-hyperflare-tp2-v16 ]'
check "v16 served id" '[ "$(hyperflare_variant_served v16)" = glm-5.3-flash-hyperflare-tp2-v16 ]'
check "uncensored model" '[ "$(hyperflare_variant_model uncensored)" = glm53-uncensored ]'
check "uncensored container" '[ "$(hyperflare_variant_container uncensored)" = glm53-flash-hyperflare-tp2-uncensored ]'
check "uncensored served id" '[ "$(hyperflare_variant_served uncensored)" = glm-5.3-flash-hyperflare-tp2-uncensored ]'

# Built checkpoints name the receipt their builder writes; v16 is downloaded, not built.
check "v16 has no build receipt" '! hyperflare_variant_build_receipt v16 >/dev/null'
check "uncensored carries the converter receipt" '[ "$(hyperflare_variant_build_receipt uncensored)" = convert-receipt.json ]'
check "the converter writes the receipt the export requires" \
  'grep -Fq "RECEIPT = \"$(hyperflare_variant_build_receipt uncensored)\"" "$ROOT/scripts/inference/glm53/glm53-uncensored-convert.py"'

# Every variant is total over the accessors; nothing is shared between two variants.
declare -A seen=()
for variant in "${HYPERFLARE_VARIANTS[@]}"; do
  for accessor in model container served; do
    value="$("hyperflare_variant_$accessor" "$variant")"
    check "$variant has a $accessor" '[ -n "$value" ]'
    check "$accessor of $variant is not another variant's" '[ -z "${seen[$accessor:$value]:-}" ]'
    seen[$accessor:$value]=$variant
  done
  check "$variant has provenance" '[ -n "$(hyperflare_variant_provenance "$variant" base@rev)" ]'
  check "$variant provenance names its base" '[[ "$(hyperflare_variant_provenance "$variant" base@rev)" == base@rev* ]]'
done

# A tune is only believable with its donor named: the label says where the weights came from.
check "uncensored provenance names the source build and revision" \
  '[[ "$(hyperflare_variant_provenance uncensored base@rev)" == *"dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4@745aac2ff0f10acf961f396df3f9418598aa7327"* ]]'
check "uncensored names the revision its downloader pins" \
  'grep -Fq "REV=\"745aac2ff0f10acf961f396df3f9418598aa7327\"" "$ROOT/scripts/inference/glm53/download-glm53-uncensored-source.sh"'
check "v16 provenance is the base alone" '[ "$(hyperflare_variant_provenance v16 base@rev)" = base@rev ]'

# Unknown variants (the retired cyber-hybrid ones included) fail closed everywhere: no model, no derived names, a named error.
for bogus in "" v17 V16 cyber cyber-hybrid cyber-hybrid-bf16 "v16 " ../v16; do
  check "unknown variant '$bogus' has no model" '! hyperflare_variant_model "$bogus" >/dev/null 2>&1'
  check "unknown variant '$bogus' has no container" '! hyperflare_variant_container "$bogus" >/dev/null 2>&1'
  check "unknown variant '$bogus' has no served id" '! hyperflare_variant_served "$bogus" >/dev/null 2>&1'
  check "unknown variant '$bogus' has no provenance" '! hyperflare_variant_provenance "$bogus" base@rev >/dev/null 2>&1'
  check "unknown variant '$bogus' has no build receipt" '! hyperflare_variant_build_receipt "$bogus" >/dev/null 2>&1'
done
status=0
err="$(hyperflare_resolve_model nope 2>&1 >/dev/null)" || status=$?
check "resolve refuses an unknown variant with status 2" '[ "$status" = 2 ]'
check "resolve names the known variants" '[[ "$err" == *"unknown VARIANT '"'"'nope'"'"'"*"v16 uncensored"* ]]'
check "resolve prints the model for a known variant" '[ "$(hyperflare_resolve_model uncensored)" = glm53-uncensored ]'

if [ "$failures" -ne 0 ]; then
  echo "hyperflare-variants unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "hyperflare-variants unit: PASS ($cases checks)"
