#!/bin/sh
# Apply THIS machine's NixOS configuration.
#
# Home-manager is integrated (home-manager.users, see flake.nix `hmUsers`),
# so this single command applies system and home atomically — no separate
# hm-apply step. `--flake .#` selects the host by the machine's hostname.
#
# After the switch, prints a recap of each home-manager service's activation
# from this rebuild — the pi/claude/nvim/home.activation hooks now run
# inside that service rather than in your terminal, so this is where their
# output lives.
#
# `--boot` builds and installs the generation for the next boot without
# activating it (`nixos-rebuild boot`): for a kernel or driver change on a box
# that is serving, so nothing restarts under it until it reboots.
set -u
ROOT=$(cd "$(dirname "$0")" && pwd)
START=$(date +%s)
action=switch
if [ "${1:-}" = --boot ]; then
  action=boot
  shift
fi
sudo nixos-rebuild "$action" --flake .# "$@"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "nixos-rebuild $action failed (exit $rc) — skipping home recap" >&2
  exit "$rc"
fi

# A boot default pinned in EFI (`bootctl set-default`, see
# docs/runbooks/gaming-desktop.md) names one generation's entry file, and it
# outranks loader.conf: left alone, the machine keeps booting the generation it
# was pinned on (desktop 2026-10-22 booted 73 over 74; 2026-11-08 booted 75 over
# 78, dropping the ds4-native metrics bridge until 79 was applied 2026-11-12).
# Move an existing pin to this generation's headless entry; machines without a
# pin are untouched. The move is verified rather than assumed — silently
# leaving an old pin is how the desktop kept reverting to a pre-fix system.
pin=/sys/firmware/efi/efivars/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
pin_rc=0
if [ -e "$pin" ]; then
  gen=$(readlink /nix/var/nix/profiles/system | sed -n 's/^system-\([0-9]*\)-link$/\1/p')
  entry=$(sudo "$ROOT/scripts/boot-pin-entry.sh" "$gen" 2>/dev/null) || entry=
  if [ -z "$entry" ]; then
    echo "warning: no headless boot entry for generation $gen — the EFI pin still names an older generation" >&2
    pin_rc=1
  elif ! sudo bootctl set-default "$entry"; then
    echo "warning: bootctl set-default $entry failed — the EFI pin still names an older generation" >&2
    pin_rc=1
  else
    pinned=$(sudo tail -c +5 "$pin" | tr -d '\000')
    if [ "$pinned" = "$entry" ]; then
      echo "boot default pinned to generation $gen headless: $entry"
    else
      echo "warning: EFI pin reads '$pinned', expected '$entry' — the next boot would leave generation $gen" >&2
      pin_rc=1
    fi
  fi
fi

if [ "$action" = boot ]; then
  echo "generation $(readlink /nix/var/nix/profiles/system) installed for the next boot; nothing activated"
  exit "$pin_rc"
fi

for unit in $(sudo systemctl list-unit-files --no-legend 'home-manager-*.service' 2>/dev/null | awk '{print $1}'); do
  echo
  echo "── home activation: $unit (this rebuild)"
  out=$(sudo journalctl -u "$unit" --since "@$START" --no-pager -q 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | tail -n 40
  else
    echo "   (no activation ran this rebuild — home config unchanged)"
  fi
done

exit "$pin_rc"
