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

### Secure Template-Based Usage (RECOMMENDED)
Templates prevent secrets from entering the Nix store - use this approach for security:

```nix
{ util, config, lib, ... }:

# SECURE: Template-based approach
(util.sops.mkSecretsAndTemplatesConfig
  # 1. Define secrets (encrypted references)
  [
    (util.sops.userSecret "github-token" "personal-github.yaml" "token")
    (util.sops.hostSecret "api-key" "service.yaml" "api_key")
  ]
  
  # 2. Define templates (rendered files with actual values)
  [
    # Environment file template
    (util.sops.envTemplate "app-env" {
      GITHUB_TOKEN = "github-token";
      API_KEY = "api-key";
    })
    
    # Config file template
    (util.sops.configTemplate "app-config" ''
      api_key = ${config.sops.placeholder."api-key"}
      token = ${config.sops.placeholder."github-token"}
    '')
  ]
  
  # 3. Regular configuration
  {
    # Use rendered templates (contain actual secret values)
    systemd.services.myapp = {
      serviceConfig.EnvironmentFile = config.sops.templates."app-env".path;
    };
  }
) { inherit config lib; }

# Access templates via: config.sops.templates.template-name.path
```

### Legacy Direct Access (Less Secure)
Only use when templates aren't suitable:

```nix
{ util, config, ... }:

# WARNING: May expose secrets in nix store
(util.sops.mkSecretsConfig [
  (util.sops.userSecret "github-token" "personal-github.yaml" "token")
] {
  # Access secrets via: config.sops.secrets.github-token.path
}) { inherit config lib; }
```

### Dynamic Secret Helpers
- `userSecret`: Resolves to `secrets/users/{current-user}/`
- `hostSecret`: Resolves to `secrets/hosts/{current-host}/`  
- `commonSecret`: Resolves to `secrets/common/`

### Template Locations
- **NixOS**: `/run/secrets/rendered/{template-name}`
- **Home Manager**: `~/.config/sops-nix/secrets/rendered/{template-name}`

### Encrypting Secrets
```bash
# Encrypt new secret file
sops -e -i secrets/users/username/new-secret.yaml

# Edit existing encrypted file  
sops secrets/hosts/hostname/service.yaml
```

### Testing Templates
```bash
# Verify template content (should show placeholders, not actual secrets)
nix eval .#nixosConfigurations.hostname.config.sops.templates.template-name.content

# Templates should contain: <SOPS:hash:PLACEHOLDER>
```