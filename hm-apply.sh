#!/bin/sh
# Apply a home-manager configuration. Defaults to the config named after the
# current user ($USER); pass a name to pick another, e.g. `./hm-apply.sh desktop`.
CFG="${1:-$USER}"
# Back up (don't clobber) any pre-existing files HM did not create itself. This
# matters the first time a host moves from HM-as-NixOS-module to standalone HM.
export HOME_MANAGER_BACKUP_EXT="${HOME_MANAGER_BACKUP_EXT:-hm-bak}"
nix build ".#homeManagerConfigurations.${CFG}.activationPackage" --impure
result/activate
