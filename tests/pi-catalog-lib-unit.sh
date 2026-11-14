#!/usr/bin/env bash
# Unit test for tests/lib/pi-catalog.sh: absent ids pass; a present id, a
# catalog without a desktop-vllm list, and unreadable JSON each fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
checks=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# run_case NAME CATALOG_JSON EXPECTED_STATUS EXPECTED_STDERR_FRAGMENT ID...
run_case() {
  local name="$1" catalog="$2" expected="$3" fragment="$4"
  shift 4
  printf '%s' "$catalog" > "$sandbox/models.json"
  local status=0 stderr
  stderr="$(PI_CATALOG_FILE="$sandbox/models.json" bash -c \
    'source "$1"; shift; assert_not_in_pi_catalog "$@"' _ "$ROOT/tests/lib/pi-catalog.sh" "$@" 2>&1 >/dev/null)" \
    || status=$?
  [[ "$status" -eq "$expected" ]] || fail "$name: exit $status, expected $expected ($stderr)"
  [[ -z "$fragment" || "$stderr" == *"$fragment"* ]] || fail "$name: stderr lacks '$fragment': $stderr"
  checks=$((checks + 1))
}

primaries='{"providers":{"desktop-vllm":{"models":[{"id":"warmind-1017-native"},{"id":"glm-5.3-flash-hyperflare-tp2-v16"}]}}}'

run_case "absent ids pass" "$primaries" 0 "" qwen3.8-27b glm-5.3-flash-qad2-tp2-v15
run_case "no ids pass" "$primaries" 0 ""
run_case "a present id fails" "$primaries" 1 "offers glm-5.3-flash-hyperflare-tp2-v16" \
  qwen3.8-27b glm-5.3-flash-hyperflare-tp2-v16
run_case "a missing provider fails" '{"providers":{}}' 1 "has no desktop-vllm model list" qwen3.8-27b
run_case "a non-list models field fails" '{"providers":{"desktop-vllm":{"models":"x"}}}' 1 \
  "has no desktop-vllm model list" qwen3.8-27b
run_case "unreadable JSON fails" '{not json' 1 "cannot read" qwen3.8-27b

# The real catalog: the primaries are present, a retired id is absent.
run_case "the installed catalog lacks retired ids" "$(cat "$ROOT/pi/models.json")" 0 "" qwen3.8-27b
run_case "the installed catalog offers WARMIND" "$(cat "$ROOT/pi/models.json")" 1 "offers warmind-1017-native" \
  warmind-1017-native

printf 'PASS: pi-catalog assertions (%d cases)\n' "$checks"
