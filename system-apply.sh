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
