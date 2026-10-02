#!/usr/bin/env bash
# Contract for ensure-xmonad-binary.sh: the compiled xmonad binary is rebuilt
# when missing, stale, or linked against deleted libraries — and left alone
# otherwise. Uses plain fake executables, no mocking framework.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/roles/home-manager/window-manager/xmonad/ensure-xmonad-binary.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
dir="$work/.xmonad"
bin="$dir/xmonad-x86_64-linux"
calls="$work/calls"
mkdir -p "$dir"
: >"$dir/xmonad.hs"

# Fake xmonad: --recompile records the call and writes a healthy binary,
# unless FAKE_COMPILE_FAILS is set.
cat >"$work/xmonad" <<FAKE
#!/usr/bin/env bash
echo recompile >>"$calls"
[ -z "\${FAKE_COMPILE_FAILS:-}" ] || exit 1
printf 'GOOD\n' >"$bin"
chmod +x "$bin"
FAKE
# Fake ldd: reports an unresolved library when the binary says BROKEN.
cat >"$work/ldd" <<'FAKE'
#!/usr/bin/env bash
if grep -q BROKEN "$1"; then echo 'libXft.so.2 => not found'; else echo 'libc.so.6 => /lib/libc.so.6'; fi
FAKE
chmod +x "$work/xmonad" "$work/ldd"

run() { "$SCRIPT" "$work/xmonad" "$dir" x86_64-linux "$1" "$work/ldd" >/dev/null 2>&1; }
count() { if [ -f "$calls" ]; then wc -l <"$calls" | tr -d ' '; else echo 0; fi; }

# 1. missing binary -> compile
run cfgA
[ "$(count)" = 1 ] || fail "missing binary was not compiled"
[ -x "$bin" ] || fail "binary not produced"

# 2. healthy + same config -> idempotent no-op
run cfgA
[ "$(count)" = 1 ] || fail "healthy binary was recompiled (not idempotent)"

# 3. config changed -> compile (independent of mtime: xmonad.hs is a store symlink)
run cfgB
[ "$(count)" = 2 ] || fail "config change did not trigger a rebuild"

# 4. unresolved libs (GC'd store paths) -> compile and replace the binary
printf 'BROKEN\n' >"$bin"
run cfgB
[ "$(count)" = 3 ] || fail "unresolved libraries did not trigger a rebuild"
grep -q GOOD "$bin" || fail "broken binary was not replaced"

# 5. failed compile must not abort activation, and must not record the stamp
rm -f "$bin" "$dir/.compiled-from"
FAKE_COMPILE_FAILS=1 "$SCRIPT" "$work/xmonad" "$dir" x86_64-linux cfgB "$work/ldd" >/dev/null 2>&1 \
  || fail "failed compile returned non-zero (would abort home-manager activation)"
[ ! -f "$dir/.compiled-from" ] || fail "stamp written after failed compile"

# 6. no xmonad (headless host) -> nothing to do
before="$(count)"
"$SCRIPT" "$work/does-not-exist" "$dir" x86_64-linux cfgB "$work/ldd" >/dev/null 2>&1
[ "$(count)" = "$before" ] || fail "ran on a host without xmonad"

printf 'PASS: xmonad binary is rebuilt when missing, stale or broken, and left alone otherwise\n'
