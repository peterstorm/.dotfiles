#!/bin/sh
# Apply the home-manager config for this machine.
#
# NixOS hosts (desktop, laptops, homelab): home-manager is integrated into
# the system build via home-manager.users (see flake.nix `hmUsers`), so
# `./system-apply.sh` (one nixos-rebuild switch) applies system AND home
# atomically. This script is a no-op there — it exists so the old muscle
# memory keeps working, and it tells you which command actually applies
# the home config.
#
# Non-NixOS hosts (the work Mac): builds the standalone
# homeManagerConfigurations profile named after the current user ($USER);
# pass a name to pick another, e.g. `./hm-apply.sh hansen142`.
CFG="${1:-$USER}"
HOST="$(hostname)"
# A host with an integrated config appears in flake.nix as
# `<host> = host.mkHost {`. Checked against the flake source so this stays
# in sync without an expensive eval.
if grep -qE "^[[:space:]]+${HOST} = host\.mkHost \{" flake.nix; then
  echo "host '$HOST' integrates home-manager into its NixOS config (home-manager.users)."
  echo "Apply it with ./system-apply.sh — one nixos-rebuild switch covers system and home."
  exit 0
fi
# Back up (don't clobber) any pre-existing files HM did not create itself. This
# matters the first time a host moves from HM-as-NixOS-module to standalone HM.
export HOME_MANAGER_BACKUP_EXT="${HOME_MANAGER_BACKUP_EXT:-hm-bak}"
nix build ".#homeManagerConfigurations.${CFG}.activationPackage" --impure
result/activate
