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
set -u
START=$(date +%s)
sudo nixos-rebuild switch --flake .# "$@"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "nixos-rebuild failed (exit $rc) — skipping home recap" >&2
  exit "$rc"
fi

# A boot default pinned in EFI (`bootctl set-default`, see
# docs/runbooks/gaming-desktop.md) names one generation's entry file, and it
# outranks loader.conf: left alone, the machine keeps booting the generation it
# was pinned on (desktop 2026-10-22 booted 73 over 74). Move an existing pin to
# this generation's headless entry; machines without a pin are untouched.
pin=/sys/firmware/efi/efivars/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
if [ -e "$pin" ]; then
  gen=$(readlink /nix/var/nix/profiles/system | sed -n 's/^system-\([0-9]*\)-link$/\1/p')
  entry=$(sudo bootctl list --json=short | jq -r --arg v "Generation $gen " \
    'first(.[] | select(.title == "NixOS" and (.version | startswith($v))) | .id) // empty')
  if [ -n "$entry" ] && sudo bootctl set-default "$entry"; then
    echo "boot default pinned to generation $gen headless: $entry"
  else
    echo "warning: no headless boot entry for generation $gen — boot default still pinned to an older generation" >&2
  fi
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
