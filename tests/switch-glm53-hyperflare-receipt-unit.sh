#!/usr/bin/env bash
# Unit test for report_boot_receipt in switch-glm53-hyperflare-tp2-v16.sh: the
# switcher calls it with errexit suppressed, so every failing step must return
# non-zero with a named error, print no "BOOT RECEIPT:" line, leave no temporary
# file and keep any previous receipt; the success path writes the receipt.
# docker, mktemp, chmod and mv are stubbed; no container or GPU is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-hyperflare-tp2-v16.sh"

# Sourcing must never run main, whatever $0 is (see tests/switch-primary-unit.sh):
# a stub docker first on PATH records any call the start/stop dispatch would make.
guard_bin="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "docker $*" >>"%s/calls"\n' "$guard_bin" >"$guard_bin/docker"
chmod +x "$guard_bin/docker"
PATH="$guard_bin:$PATH" bash -c 'source "$0" stop' "$SWITCH" >/dev/null 2>&1 || true
if [ -e "$guard_bin/calls" ]; then
  echo "FAIL: sourcing $SWITCH ran its dispatch: $(cat "$guard_bin/calls")" >&2
  exit 1
fi
rm -rf "$guard_bin"

# shellcheck source=scripts/inference/glm53/switch-glm53-hyperflare-tp2-v16.sh
source "$SWITCH"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
BOOT_RECEIPT="$sandbox/state/receipt.txt"
failures=0
cases=0

fail_step=""
docker() {
  case "$1 ${4:-}" in
    "logs "*) [ "$fail_step" != logs ] || return 1
      printf '%s\n' 'Plan cache. per GPU: 86.56 GiB loaded' 'Allocate cache. 15.4 GiB · 2231808 KV tokens' ;;
    "inspect {{.Image}}") [ "$fail_step" != image ] || return 1; echo sha256:feed ;;
    "inspect {{.State.StartedAt}}") [ "$fail_step" != started ] || return 1; echo 2026-11-14T20:00:00Z ;;
    "inspect "*) [ "$fail_step" != package ] || return 1; echo glm53-fp4-local@gb202-tp2-202611141415 ;;
    *) echo "unexpected docker $*" >&2; return 9 ;;
  esac
}
mktemp() { [ "$fail_step" != mktemp ] || return 1; command mktemp "$@"; }
chmod() { [ "$fail_step" != chmod ] || return 1; command chmod "$@"; }
mv() { [ "$fail_step" != mv ] || return 1; command mv "$@"; }

# expect_failure STEP MESSAGE: a failing STEP returns 1 with MESSAGE, no
# success line, no temporary file, and the previous receipt untouched.
expect_failure() {
  local step="$1" message="$2" status=0 out
  cases=$((cases + 1))
  mkdir -p "$(dirname "$BOOT_RECEIPT")"
  printf 'previous\n' >"$BOOT_RECEIPT"
  fail_step="$step"
  out="$( (report_boot_receipt) 2>&1)" || status=$?
  fail_step=""
  if [ "$status" -ne 1 ] || [[ "$out" != *"error: boot receipt: $message"* ]] || [[ "$out" == *"BOOT RECEIPT:"* ]] \
    || compgen -G "$(dirname "$BOOT_RECEIPT")/.v16-boot-receipt.*" >/dev/null \
    || [ "$(cat "$BOOT_RECEIPT")" != previous ]; then
    failures=$((failures + 1))
    echo "FAIL $step: status=$status out=$out" >&2
  fi
}

expect_failure logs "docker logs $TARGET failed"
expect_failure image "docker inspect (image) failed"
expect_failure started "docker inspect (start time) failed"
expect_failure package "docker inspect (package label) failed"
expect_failure mktemp "cannot create a temporary file in"
expect_failure chmod "cannot chmod"
expect_failure mv "cannot move the receipt to $BOOT_RECEIPT"

# Success: the receipt names the container, model, package and capacity lines.
cases=$((cases + 1))
rm -rf "$sandbox/state"
status=0
out="$( (report_boot_receipt) 2>&1)" || status=$?
expected_line="BOOT RECEIPT: $BOOT_RECEIPT (model=$EXPECTED_MODEL, package=glm53-fp4-local@gb202-tp2-202611141415)"
if [ "$status" -ne 0 ] || [ "$out" != "$expected_line" ] \
  || ! grep -Fxq "container=$TARGET" "$BOOT_RECEIPT" \
  || ! grep -Fxq 'image=sha256:feed' "$BOOT_RECEIPT" \
  || ! grep -Fq 'Allocate cache. 15.4 GiB' "$BOOT_RECEIPT" \
  || [ "$(stat -c %a "$BOOT_RECEIPT")" != 600 ] \
  || compgen -G "$sandbox/state/.v16-boot-receipt.*" >/dev/null; then
  failures=$((failures + 1))
  echo "FAIL success: status=$status out=$out" >&2
fi

if [ "$failures" -ne 0 ]; then
  echo "switch-glm53 boot receipt unit: $failures of $cases cases FAILED" >&2
  exit 1
fi
echo "switch-glm53 boot receipt unit: PASS ($cases cases)"
