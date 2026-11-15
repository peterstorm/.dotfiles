# shellcheck shell=bash
# Contract assertions over Pi's model catalog (pi/models.json). Source it from a
# contract; it defines functions only.
#
# Since 2026-11-14 the primaries (warmind-1017-native,
# deepseek-v4.1-flash-native, glm-5.3-flash-hyperflare-tp2-v16, and since
# 2026-11-15 glm-5.3-flash-hyperflare-tp2-uncensored) are the only
# local models Pi offers (scripts/inference/switch-primary.sh). Retired profiles
# stay launchable; restore a profile's catalog entry from git history before
# pointing Pi at it.

PI_CATALOG_FILE="${PI_CATALOG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/pi/models.json}"

# assert_not_in_pi_catalog ID...
# Exits 1 when desktop-vllm offers any ID, or when the catalog cannot be read as
# a desktop-vllm model list (an unreadable catalog never passes as "absent").
assert_not_in_pi_catalog() {
  local id verdict
  for id in "$@"; do
    verdict="$(jq -r --arg id "$id" '
      .providers["desktop-vllm"].models
      | if type != "array" then "no-list"
        elif any(.[]; .id == $id) then "offered"
        else "absent" end
    ' "$PI_CATALOG_FILE" 2>/dev/null)" || verdict="unreadable"
    case "$verdict" in
      absent) ;;
      offered)
        printf 'FAIL: %s offers %s, which left the catalog with the primaries switch\n' "$PI_CATALOG_FILE" "$id" >&2
        exit 1
        ;;
      no-list)
        printf 'FAIL: %s has no desktop-vllm model list\n' "$PI_CATALOG_FILE" >&2
        exit 1
        ;;
      *)
        printf 'FAIL: cannot read %s as JSON\n' "$PI_CATALOG_FILE" >&2
        exit 1
        ;;
    esac
  done
}
