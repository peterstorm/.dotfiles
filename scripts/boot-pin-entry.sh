#!/bin/sh
# Print the filename of the headless systemd-boot entry for a NixOS generation.
#
# `bootctl set-default` (or pressing `d` in the boot menu) writes the
# persistent EFI variable LoaderEntryDefault, which outranks loader.conf. The
# variable names ONE generation's entry file, so every apply that keeps the
# unattended default headless must re-point it at the new generation. Left
# alone, the machine keeps booting the generation it was pinned on: desktop
# booted generation 75 over 76-78 from 2026-11-08 until 2026-11-12, which
# silently removed the ds4-native metrics bridge from the running system.
#
# Selection lives here, apart from system-apply.sh, so it can be exercised
# against fixture entry directories — the graphical specialisation's entries
# share the same version string, and a wrong pick silently changes what boots.
#
#   boot-pin-entry.sh GENERATION [ENTRY_DIR]
#
# Prints the entry filename (e.g. nixos-eece903d….conf) and exits 0 on a match,
# exits 1 when that generation has no headless entry, exits 2 on a malformed
# invocation or a missing entry directory.
set -eu

gen=${1:-}
dir=${2:-/boot/loader/entries}

case "$gen" in
  '' | *[!0-9]*)
    echo "usage: boot-pin-entry.sh GENERATION [ENTRY_DIR]" >&2
    exit 2
    ;;
esac

[ -d "$dir" ] || {
  echo "no systemd-boot entry directory: $dir" >&2
  exit 2
}

for entry in "$dir"/*.conf; do
  [ -f "$entry" ] || continue
  title=$(sed -n 's/^title //p' "$entry" | head -n 1)
  [ "$title" = "NixOS" ] || continue
  version=$(sed -n 's/^version //p' "$entry" | head -n 1)
  case "$version" in
    "Generation $gen "*) basename "$entry"; exit 0 ;;
  esac
done

exit 1
