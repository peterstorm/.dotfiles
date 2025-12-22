# Copilot Instructions

## Project Overview

NixOS dotfiles repository using **flake-parts** for modular system and home-manager configurations. Supports multiple hosts (laptop-xps, laptop-work, desktop, homelab) and users (peterstorm, hansen142, homelab) across x86_64-linux and aarch64-darwin.

## Architecture

### Core Pattern: Role-Based Configuration
- **Hosts** created via `host.mkHost` in `flake.nix` with roles, hardware, and users
- **Users** created via `user.mkHMUser` in `flake.nix` with roles
- **Roles** are composable NixOS/home-manager modules in `roles/` (NixOS) and `roles/home-manager/` (user)

```nix
# Example: Adding a role to a host
roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" ];

# Example: Adding a role to a user
roles = [ "core-apps" "window-manager/xmonad" "dunst" ];
```

### Key Directories
- `lib/` - Utility functions (`host.nix`, `user.nix`, `sops.nix`, `shell.nix`)
- `roles/` - NixOS system roles (core, graphics, networking, k3s, etc.)
- `roles/home-manager/` - User roles (core-apps, window-manager, games, etc.)
- `machines/` - Hardware-specific configs per host
- `secrets/` - SOPS-encrypted secrets (users/, hosts/, common/)
- `k8s/` - ArgoCD + Terraform for homelab Kubernetes

## Commands

```bash
# System rebuild (NixOS)
sudo nixos-rebuild switch --flake .#HOSTNAME
./system-apply.sh  # auto-detects hostname

# Home Manager
./hm-apply.sh  # builds and activates for $USER

# Testing (ALWAYS git add new files first!)
nix build .#nixosConfigurations.HOSTNAME.config.system.build.toplevel --dry-run --show-trace
nix build .#homeManagerConfigurations.USERNAME.activationPackage --dry-run --show-trace
nix flake check
```

## Secrets Management (SOPS + Age)

### Critical: Use Template-Based API for Security
Templates prevent secrets from entering the Nix store. Use `util.sops` helpers:

```nix
# In a role - see roles/sops-template-nixos-example/default.nix
(util.sops.mkSecretsAndTemplatesConfig
  [ (util.sops.hostSecret "api-key" "secrets.yaml" "api_token" {}) ]
  [ (util.sops.envTemplate "app-env" { API_KEY = "api-key"; }) ]
  { /* regular nix config */ }
)
```

### Secret Paths Convention
- User secrets: `secrets/users/{username}/filename.yaml`
- Host secrets: `secrets/hosts/{hostname}/filename.yaml`
- Shared secrets: `secrets/common/filename.yaml`

### Adding Recipients
1. Generate age key: `age-keygen -o /var/lib/sops-nix/keys.txt`
2. Add public key to `.sops.yaml`
3. Re-encrypt: `sops updatekeys secrets/path/file.yaml`

## Common Patterns

### Creating a New Role
```nix
# roles/my-role/default.nix (NixOS) or roles/home-manager/my-role/default.nix
{ config, pkgs, lib, util, ... }:
{
  # util is available for sops helpers
  # imports = [ ... ];
  # environment.systemPackages = [ ... ];
}
```

### Sub-roles via Path
Roles support paths: `"core-apps/neovim"` imports `roles/home-manager/core-apps/neovim/default.nix`

## Gotchas

- **Always `git add .` new files** - Nix flakes only see git-tracked files
- **Use `--show-trace`** when debugging - errors are often buried in verbose output
- **Darwin age keys** go to `~/Library/Application Support/sops/age/keys.txt`
- **Linux age keys** go to `/var/lib/sops-nix/keys.txt`
