#!/usr/bin/env bash
# Ensure ~/.xmonad holds a usable compiled xmonad binary.
#
# Why this exists: xmonad compiles ~/.xmonad/xmonad.hs in place and only
# recompiles when xmonad.hs is NEWER than the binary. Under home-manager,
# xmonad.hs is a /nix/store symlink (mtime 1970), so it never looks newer, and
# the binary is a plain file whose RPATH points at store paths that a garbage
# collection can delete. The result is a login that dies instantly with
# "error while loading shared libraries: libXft.so.2" and bounces back to the
# display manager. This script makes the rebuild decision explicit.
#
# Rebuild when ANY of these holds:
#   - the binary is missing
#   - it was built from a different config / xmonad wrapper (stamp mismatch)
#   - ldd reports an unresolved shared library
#
# Usage: ensure-xmonad-binary.sh XMONAD_CMD XMONAD_DIR ARCH_SUFFIX CONFIG_ID LDD_CMD
#   XMONAD_CMD   xmonad executable that supports --recompile
#   XMONAD_DIR   directory holding xmonad.hs and the compiled binary (~/.xmonad)
#   ARCH_SUFFIX  e.g. x86_64-linux (binary is XMONAD_DIR/xmonad-ARCH_SUFFIX)
#   CONFIG_ID    identity of the config (its content-addressed store path)
#   LDD_CMD      ldd executable
#
# Never exits non-zero: a failed compile must not abort home-manager activation
# (the previous binary, if any, is left in place and the failure is reported).
set -u

xmonad_cmd=$1
xmonad_dir=$2
suffix=$3
config_id=$4
ldd_cmd=$5

bin="$xmonad_dir/xmonad-$suffix"
stamp="$xmonad_dir/.compiled-from"

# Hosts without the xmonad window manager (e.g. headless) have nothing to do.
if [ ! -x "$xmonad_cmd" ] || [ ! -e "$xmonad_dir/xmonad.hs" ]; then
  exit 0
fi

want="$config_id
$(readlink -f "$xmonad_cmd")"

unresolved() { "$ldd_cmd" "$bin" 2>&1 | grep -q 'not found'; }

reason=""
if [ ! -x "$bin" ]; then
  reason="binary missing"
elif [ "$(cat "$stamp" 2>/dev/null || true)" != "$want" ]; then
  reason="built from different config or xmonad"
elif unresolved; then
  reason="unresolved shared libraries"
fi

[ -n "$reason" ] || exit 0

echo "xmonad: recompiling ($reason)"
if "$xmonad_cmd" --recompile && [ -x "$bin" ] && ! unresolved; then
  printf '%s\n' "$want" >"$stamp"
  echo "xmonad: recompiled $bin"
else
  echo "xmonad: WARNING recompile failed or produced an unusable binary; run 'xmonad --recompile' to see errors" >&2
fi
exit 0
