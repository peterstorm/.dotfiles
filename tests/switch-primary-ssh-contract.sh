#!/usr/bin/env bash
# Contract test for switch-primary.sh's off-host re-exec: run anywhere but the
# serving host, it must hand the request to `ssh desktop ...`. Runs the real
# script as a subprocess with stub `hostname` and `ssh` on PATH, under the
# system bash (macOS's 3.2 where it exists): that is the shell that once died
# with "tty[@]: unbound variable" because an empty array expanded under
# `set -u`, which is exactly what happens when stdin is not a terminal.
# shellcheck disable=SC2016 # check() eval's single-quoted conditions on purpose
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/inference/switch-primary.sh"
SHELL_UNDER_TEST=/bin/bash
[ -x "$SHELL_UNDER_TEST" ] || SHELL_UNDER_TEST="$(command -v bash)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf '#!/bin/sh\necho not-the-serving-host\n' >"$work/bin/hostname"
# The ssh stub records one argument per line, so word splitting is visible.
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s/ssh-args"\n' "$work" >"$work/bin/ssh"
chmod +x "$work/bin/hostname" "$work/bin/ssh"

failures=0
cases=0
check() {
  cases=$((cases + 1))
  if ! eval "$2"; then
    failures=$((failures + 1))
    echo "FAIL $1" >&2
  fi
}

# run_off_host ARGS...: stdin is /dev/null, so the script sees no terminal.
run_off_host() {
  rm -f "$work/ssh-args"
  rc=0
  PATH="$work/bin:$PATH" "$SHELL_UNDER_TEST" "$SCRIPT" "$@" </dev/null >"$work/out" 2>&1 || rc=$?
}

run_off_host status
check "off the serving host with no tty, the re-exec reaches ssh (rc=$rc, $(cat "$work/out"))" '[ "$rc" = 0 ] && [ -f "$work/ssh-args" ]'
check "no tty means no -t flag, and ssh gets the host first" '[ "$(sed -n 1p "$work/ssh-args")" = desktop ]'
check "the request is forwarded to the serving host's copy of the script" \
  'grep -q "switch-primary.sh status" "$work/ssh-args"'

run_off_host glm-native
check "a named primary is forwarded too" 'grep -q "switch-primary.sh glm-native" "$work/ssh-args"'

run_off_host
check "no argument forwards a bare invocation (the script defaults to toggle)" \
  '[ "$rc" = 0 ] && [ "$(sed -n 1p "$work/ssh-args")" = desktop ]'

if [ "$failures" -ne 0 ]; then
  echo "switch-primary ssh contract: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "switch-primary ssh contract: PASS ($cases checks, $("$SHELL_UNDER_TEST" --version | head -1))"
