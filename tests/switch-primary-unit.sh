#!/usr/bin/env bash
# Unit tests for switch-primary.sh's functional core (primary_decide and the
# served-id mapping). Pure: sources the script without running main, so no
# Docker, GPU or ssh. Exhaustive over the input space rather than examples:
# every (request, active, last, last_ds41) combination is checked against the
# properties the switcher relies on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/inference/switch-primary.sh
source "$ROOT/scripts/inference/switch-primary.sh"

failures=0
cases=0
check() {
  cases=$((cases + 1))
  if ! eval "$2"; then
    failures=$((failures + 1))
    echo "FAIL $1" >&2
  fi
}

PRIMARIES=(glm warmind deepseek)
REQUESTS=(toggle glm warmind deepseek bogus "")
ACTIVES=(glm warmind deepseek none both other:qwen38-27b-bf16 weird "")
LASTS=(glm warmind deepseek none "")
LAST_DS41S=(warmind deepseek "" junk)
engine() { case "$1" in glm) echo hyperflare ;; warmind | deepseek) echo ds4-native ;; *) echo none ;; esac; }

for request in "${REQUESTS[@]}"; do
  for active in "${ACTIVES[@]}"; do
    for last in "${LASTS[@]}"; do
      for last_ds41 in "${LAST_DS41S[@]}"; do
        d="$(primary_decide "$request" "$active" "$last" "$last_ds41")"
        ctx="request='$request' active='$active' last='$last' last_ds41='$last_ds41' -> '$d'"
        # Totality: exactly one well-formed line.
        check "total: $ctx" '[[ "$d" =~ ^(start:(glm|warmind|deepseek)|noop:(glm|warmind|deepseek)|error:.+)$ ]]'
        # Never "start" what already serves.
        check "no self-start: $ctx" '[ "$d" != "start:$active" ]'
        # Two engines or a foreign profile on the GPUs is always refused.
        if [ "$active" = both ] || [[ "$active" == other:* ]]; then
          check "refuse foreign/both: $ctx" '[[ "$d" == error:* ]]'
        fi
        case "$active" in glm | warmind | deepseek | none) valid_active=1 ;; *) valid_active=0 ;; esac
        if [ "$valid_active" = 1 ]; then
          case "$request" in
            glm | warmind | deepseek)
              # An explicit request lands on exactly that primary.
              check "explicit: $ctx" '[ "$d" = "noop:$request" ] || [ "$d" = "start:$request" ]'
              check "noop iff already: $ctx" '[ "$active" != "$request" ] || [ "$d" = "noop:$request" ]'
              ;;
            toggle)
              if [ "$active" != none ]; then
                # Toggle always crosses to the other engine.
                check "toggle crosses engines: $ctx" \
                  '[[ "$d" == start:* ]] && [ "$(engine "${d#start:}")" != "$(engine "$active")" ]'
              fi
              if [ "$active" = glm ]; then
                expected="$last_ds41"; case "$expected" in warmind | deepseek) ;; *) expected=warmind ;; esac
                check "glm toggles to last ds41 weights: $ctx" '[ "$d" = "start:$expected" ]'
              fi
              if [ "$active" = none ]; then
                case "$last" in
                  glm | warmind | deepseek) check "resume last: $ctx" '[ "$d" = "start:$last" ]' ;;
                  *) check "nothing to resume: $ctx" '[[ "$d" == error:* ]]' ;;
                esac
              fi
              ;;
            *) check "unknown request refused: $ctx" '[[ "$d" == error:* ]]' ;;
          esac
        fi
      done
    done
  done
done

# Toggle is an involution across engines: two toggles return to the start
# (the ds41 side keeps its weights).
for start in "${PRIMARIES[@]}"; do
  for last_ds41 in warmind deepseek; do
    weights="$last_ds41"; [ "$start" = glm ] || weights="$start"
    first="$(primary_decide toggle "$start" none "$weights")"
    second="$(primary_decide toggle "${first#start:}" none "$weights")"
    check "toggle twice from $start returns ($first, $second)" '[ "$second" = "start:$start" ]'
  done
done

# The served-id mapping round-trips for every primary and rejects strangers.
for primary in "${PRIMARIES[@]}"; do
  check "round-trip $primary" '[ "$(primary_of_served "$(served_of_primary "$primary")")" = "$primary" ]'
done
check "unknown served id" '[ -z "$(primary_of_served qwen3.8-27b)" ]'

if [ "$failures" -ne 0 ]; then
  echo "switch-primary unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "switch-primary unit: PASS ($cases checks)"
