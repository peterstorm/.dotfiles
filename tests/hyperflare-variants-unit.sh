#!/usr/bin/env bash
# Unit test for scripts/inference/glm53/hyperflare-variants.sh: the one table that
# says which checkpoint directory, container, served id and provenance each
# Hyperflare GLM-5.3 variant has. Pure (sourcing defines functions only).
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
check "variants are v16, cyber-hybrid and cyber-hybrid-bf16" '[ "${HYPERFLARE_VARIANTS[*]}" = "v16 cyber-hybrid cyber-hybrid-bf16" ]'
check "v16 model" '[ "$(hyperflare_variant_model v16)" = glm53-fp4-local ]'
check "v16 container" '[ "$(hyperflare_variant_container v16)" = glm53-flash-hyperflare-tp2-v16 ]'
check "v16 served id" '[ "$(hyperflare_variant_served v16)" = glm-5.3-flash-hyperflare-tp2-v16 ]'
check "cyber-hybrid model" '[ "$(hyperflare_variant_model cyber-hybrid)" = glm53-cyber-hybrid ]'
check "cyber-hybrid container" '[ "$(hyperflare_variant_container cyber-hybrid)" = glm53-flash-hyperflare-tp2-cyber-hybrid ]'
check "cyber-hybrid served id" '[ "$(hyperflare_variant_served cyber-hybrid)" = glm-5.3-flash-hyperflare-tp2-cyber-hybrid ]'
check "cyber-hybrid-bf16 model" '[ "$(hyperflare_variant_model cyber-hybrid-bf16)" = glm53-cyber-hybrid-bf16 ]'
check "cyber-hybrid-bf16 container" '[ "$(hyperflare_variant_container cyber-hybrid-bf16)" = glm53-flash-hyperflare-tp2-cyber-hybrid-bf16 ]'
check "cyber-hybrid-bf16 served id" '[ "$(hyperflare_variant_served cyber-hybrid-bf16)" = glm-5.3-flash-hyperflare-tp2-cyber-hybrid-bf16 ]'

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

# A tune is only believable with its donor named: the hybrid's label says where the dense tensors came from.
check "hybrid provenance names the donor build and revision" \
  '[[ "$(hyperflare_variant_provenance cyber-hybrid base@rev)" == *"dealignai/GLM-5.3-Flash-CYBERSECURITY-W4A16@4c2ee763ff75f3ba50652ee0f024b0b630cd54a0"* ]]'
check "bf16 provenance names the donor and the BF16 storage" \
  '[[ "$(hyperflare_variant_provenance cyber-hybrid-bf16 base@rev)" == *"CYBERSECURITY-W4A16@4c2ee763"*"BF16"* ]]'
check "v16 provenance is the base alone" '[ "$(hyperflare_variant_provenance v16 base@rev)" = base@rev ]'

# Unknown variants fail closed everywhere: no model, no derived names, a named error.
for bogus in "" v17 V16 cyber "v16 " ../v16; do
  check "unknown variant '$bogus' has no model" '! hyperflare_variant_model "$bogus" >/dev/null 2>&1'
  check "unknown variant '$bogus' has no container" '! hyperflare_variant_container "$bogus" >/dev/null 2>&1'
  check "unknown variant '$bogus' has no served id" '! hyperflare_variant_served "$bogus" >/dev/null 2>&1'
  check "unknown variant '$bogus' has no provenance" '! hyperflare_variant_provenance "$bogus" base@rev >/dev/null 2>&1'
done
status=0
err="$(hyperflare_resolve_model nope 2>&1 >/dev/null)" || status=$?
check "resolve refuses an unknown variant with status 2" '[ "$status" = 2 ]'
check "resolve names the known variants" '[[ "$err" == *"unknown VARIANT '"'"'nope'"'"'"*"v16 cyber-hybrid cyber-hybrid-bf16"* ]]'
check "resolve prints the model for a known variant" '[ "$(hyperflare_resolve_model cyber-hybrid)" = glm53-cyber-hybrid ]'

if [ "$failures" -ne 0 ]; then
  echo "hyperflare-variants unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "hyperflare-variants unit: PASS ($cases checks)"
