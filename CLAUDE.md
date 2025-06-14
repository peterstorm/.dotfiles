# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Structure

This is a NixOS/Home Manager dotfiles repository using a flake-based configuration with a modular role system. The configuration is organized around:

- **Hosts**: Multiple machine configurations (laptop-xps, laptop-work, desktop, homelab)
- **Users**: Home Manager configurations for different users (peterstorm, hansen142, homelab)
- **Roles**: Modular configuration components that can be mixed and matched

### Key Architecture Components

- `flake.nix`: Main configuration entry point defining inputs, hosts, and users
- `lib/`: Utility functions for creating hosts (`host.nix`) and users (`user.nix`)
- `roles/`: Modular configuration components split into system roles and home-manager roles
- `machines/`: Machine-specific hardware configurations
- `secrets/`: SOPS-encrypted secrets with age encryption

## Common Commands

### System Configuration
```bash
# Apply NixOS system configuration changes
./system-apply.sh
# Equivalent to: sudo nixos-rebuild switch --flake .#

# Apply Home Manager configuration changes
./hm-apply.sh
# Equivalent to: nix build .#homeManagerConfigurations.$USER.activationPackage && result/activate
```

### Secret Management
- Secrets are managed with SOPS and age encryption
- Configuration in `.sops.yaml`
- Encrypted files in `secrets/` directory

## Role System

The configuration uses a role-based system where both NixOS hosts and Home Manager users can be assigned roles:

### NixOS Roles (in `roles/`)
- `core`: Base system configuration
- `efi`, `wifi`, `bluetooth`: Hardware support
- `desktop-plasma`, `dual-desktop-plasma`: Desktop environments
- `laptop`, `nvidia-graphics`, `laptop-nvidia-graphics`: Hardware-specific
- `ssh`, `k3s`, `cloudflared`: Services

### Home Manager Roles (in `roles/home-manager/`)
- `core-apps`: Base applications (git, starship, etc.)
- `core-apps/neovim`, `core-apps/tmux`: Specific applications
- `window-manager/xmonad`: XMonad configuration
- `dunst`: Notification daemon
- `games`: Gaming applications

## User and Host Creation

New hosts are created using `host.mkHost` with roles, hardware configuration, and user definitions.
New users are created using `user.mkHMUser` with their specific roles and username.