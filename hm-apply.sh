#!/bin/sh
# Apply a STANDALONE home-manager configuration — non-NixOS hosts only (the
# work Mac). Defaults to the config named after the current user ($USER);
# pass a name to pick another, e.g. `./hm-apply.sh hansen142`.
#
# NixOS hosts (desktop, laptops, homelab) do NOT use this script: their
# home-manager config is integrated into the system build via
# home-manager.users (see flake.nix hmUsers), so `nixos-rebuild switch`
# applies system and home atomically.
CFG="${1:-$USER}"
# Back up (don't clobber) any pre-existing files HM did not create itself. This
# matters the first time a host moves from HM-as-NixOS-module to standalone HM.
export HOME_MANAGER_BACKUP_EXT="${HOME_MANAGER_BACKUP_EXT:-hm-bak}"
nix build ".#homeManagerConfigurations.${CFG}.activationPackage" --impure
result/activate
