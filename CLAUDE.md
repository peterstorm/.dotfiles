# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### System Configuration
- `sudo nixos-rebuild switch --flake .#` - Apply NixOS system configuration
- `./system-apply.sh` - Convenience script for system rebuild

### Home Manager
- `nix build .#homeManagerConfigurations.$USER.activationPackage && result/activate` - Build and activate home manager configuration
- `./hm-apply.sh` - Convenience script for home manager activation

### Development
- `nix flake update` - Update flake inputs
- `nix flake check` - Validate flake configuration
- `nix develop` - Enter development shell (if available)

**Important for Nix Development**:
- When refactoring Nix code, always examine the full build logs when testing. Nix error messages can be verbose and the root cause is often buried in the output. Use `--show-trace` flag for detailed error traces when debugging.
- Always `git add .` newly created files before testing - Nix flakes only see files that are tracked by git.

## Architecture

This is a NixOS dotfiles repository structured using flake-parts for modular configuration management.

### Core Structure
- `flake.nix` - Main flake configuration defining inputs, systems, and outputs
- `lib/` - Utility functions for creating hosts and users
  - `host.nix` - Functions for creating NixOS system configurations
  - `user.nix` - Functions for creating home-manager and system user configurations
- `roles/` - Modular configuration components that can be applied to hosts/users
- `machines/` - Hardware-specific configurations for individual machines
- `modules/` - Custom NixOS modules

### Configuration System
The repository uses a role-based system where:
- Hosts are created with `host.mkHost` specifying roles, hardware details, and users
- Home manager users are created with `user.mkHMUser` specifying roles and username
- Roles are modular components in `roles/` and `roles/home-manager/` directories

### Current Configurations
- **NixOS Systems**: laptop-xps, laptop-work, desktop, homelab
- **Home Manager Users**: peterstorm, hansen142, homelab
- **Key Roles**: core, desktop environments (plasma/xmonad), graphics drivers, networking

### Kubernetes/Infrastructure
- `k8s/` - ArgoCD-based Kubernetes configurations for homelab
- `k8s/terraform/` - Terraform configurations for infrastructure
- Uses external-secrets, cert-manager, and various self-hosted applications

The system supports multiple architectures (x86_64-linux, aarch64-darwin) and uses sops-nix for secrets management.

## Secrets Management with SOPS

### SOPS Integration
- **NixOS**: sops-nix module imported in core role with age key at `/var/lib/sops-nix/keys.txt`
- **Home Manager**: sops-nix module and age key configuration automatically included
- **Library**: Custom sops utilities available as `util.sops` in all roles

### Secrets Directory Structure
```
secrets/
├── common/          # Shared across all hosts/users
├── hosts/{hostname}/ # Host-specific secrets (NixOS)
└── users/{username}/ # User-specific secrets (home-manager)
```

### Usage in Roles
```nix
{ util, config, ... }:

util.sops.mkSecrets [
  # Auto-detect context and ownership
  { name = "github-token"; file = "secrets/users/peterstorm/github.yaml"; key = "token"; }
  
  # Explicit configuration
  { name = "api-key"; file = "secrets/common/api.yaml"; key = "key"; owner = "nginx"; mode = "0440"; }
] { inherit config; }

# Access secrets via: config.sops.secrets.github-token.path
```

### Encrypting Secrets
```bash
# Encrypt new secret file
sops -e -i secrets/common/new-secret.yaml

# Edit existing encrypted file  
sops secrets/users/peterstorm/github.yaml
```