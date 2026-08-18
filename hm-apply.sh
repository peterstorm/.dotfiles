#!/bin/sh
# Apply this machine's home-manager profile.
#
# NixOS hosts (desktop, laptops, homelab): the home-manager profile is
# integrated into the system build (home-manager.users, see flake.nix
# `hmUsers`) — there is no separate home artifact to build and activate.
# Applying the profile means running the system rebuild, so this delegates
# to ./system-apply.sh: one atomic switch applies the home profile
# (xmonad, nvim, secrets, ...) together with the system. Note: on these
# hosts ./hm-apply.sh and ./system-apply.sh do the same thing.
#
# Non-NixOS hosts (the work Mac): builds the standalone
# homeManagerConfigurations profile named after the current user ($USER);
# pass a name to pick another, e.g. `./hm-apply.sh hansen142`.
CFG="${1:-$USER}"
HOST="$(hostname)"
# A host with an integrated profile appears in flake.nix as
# `<host> = host.mkHost {`. Checked against the flake source so this stays
# in sync without an expensive eval.
if grep -qE "^[[:space:]]+${HOST} = host\.mkHost \{" flake.nix; then
  exec ./system-apply.sh
fi
# Back up (don't clobber) any pre-existing files HM did not create itself. This
# matters the first time a host moves from HM-as-NixOS-module to standalone HM.
export HOME_MANAGER_BACKUP_EXT="${HOME_MANAGER_BACKUP_EXT:-hm-bak}"
nix build ".#homeManagerConfigurations.${CFG}.activationPackage" --impure
result/activate
