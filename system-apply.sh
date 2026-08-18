#!/bin/sh
# Apply THIS machine's NixOS configuration.
#
# Home-manager is integrated (home-manager.users, see flake.nix `hmUsers`),
# so this single command applies system and home atomically — no separate
# hm-apply step. `--flake .#` selects the host by the machine's hostname.
sudo nixos-rebuild switch --flake .# "$@"
