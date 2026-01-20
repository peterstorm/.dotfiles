# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### System Configuration
- `sudo nixos-rebuild switch --flake .#HOSTNAME` - Apply NixOS system configuration (replace HOSTNAME with: laptop-xps, laptop-work, desktop, or homelab)
- `./system-apply.sh` - Convenience script for system rebuild (note: script needs hostname auto-detection or manual specification)

### Home Manager
- `nix build .#homeManagerConfigurations.$USER.activationPackage && result/activate` - Build and activate home manager configuration
- `./hm-apply.sh` - Convenience script for home manager activation

### Development
- `nix flake update` - Update all flake inputs
- `nix flake lock --update-input INPUT_NAME` - Update specific input (e.g., nixpkgs)
- `nix flake check` - Validate flake configuration
- `nix develop` - Enter development shell (if available)

### Updating Dependencies
```bash
# Update all inputs
nix flake update

# Update specific input
nix flake lock --update-input nixpkgs

# Test after updating (always test before committing updates)
nix flake check
```

### Testing

**Prerequisites**:
- Always `git add .` newly created files before testing - Nix flakes only see git-tracked files

**Test Commands**:
- `nix build .#nixosConfigurations.HOSTNAME.config.system.build.toplevel --dry-run --show-trace` - Test NixOS config builds without downloading/building
- `nix build .#homeManagerConfigurations.USERNAME.activationPackage --dry-run --show-trace` - Test home-manager config builds without downloading/building
- `nix eval .#nixosConfigurations.HOSTNAME.config.sops.templates --apply 'builtins.attrNames'` - List SOPS templates for a host
- `nix eval .#homeManagerConfigurations.USERNAME.config.sops.templates.TEMPLATE_NAME.content` - Preview SOPS template content (should show placeholders)

**Important for Nix Development**:
- When refactoring Nix code, always examine the full build logs when testing. Nix error messages can be verbose and the root cause is often buried in the output. Use `--show-trace` flag for detailed error traces when debugging.
- Always `git add .` newly created files before testing - Nix flakes only see files that are tracked by git.

## Architecture

This is a NixOS dotfiles repository structured using flake-parts for modular configuration management.

### Core Structure
- `flake.nix` - Main flake configuration defining inputs, systems, and outputs
- `lib/` - Utility functions for creating hosts and users
  - `default.nix` - Exports unified utility interface (host, user, shell, sops)
  - `host.nix` - Functions for creating NixOS system configurations
  - `user.nix` - Functions for creating home-manager and system user configurations
  - `sops.nix` - SOPS helper functions for secrets management
  - `shell.nix` - Shell utilities
- `roles/` - Modular configuration components that can be applied to hosts/users
- `machines/` - Hardware-specific configurations for individual machines
- `modules/` - Custom NixOS modules

### Configuration System
The repository uses a role-based system where:
- Hosts are created with `host.mkHost` specifying roles, hardware details, and users
- Home manager users are created with `user.mkHMUser` specifying roles and username
- Roles are modular components in `roles/` and `roles/home-manager/` directories
- Roles are standalone Nix modules that can be composed together via the `roles` list in flake.nix

### Current Configurations
- **NixOS Systems**: laptop-xps, laptop-work, desktop, homelab
- **Home Manager Users**: peterstorm, hansen142, homelab
- **Key Roles**: core, desktop environments (plasma/xmonad), graphics drivers, networking

### Kubernetes/Infrastructure
- `k8s/` - ArgoCD-based Kubernetes configurations for homelab
- `k8s/terraform/` - Terraform configurations for infrastructure
- Uses external-secrets, cert-manager, and various self-hosted applications

The system supports multiple architectures (x86_64-linux, aarch64-darwin) and uses sops-nix for secrets management.

## Quick Start

### Adding a New NixOS Host
1. Create hardware config: `machines/new-host/default.nix`
2. Add SOPS age key recipient to `.sops.yaml`
3. Define host in `flake.nix` using `host.mkHost`
4. Generate age key on new host: `mkdir -p /var/lib/sops-nix && age-keygen -o /var/lib/sops-nix/keys.txt`
5. Get public key: `age-keygen -y /var/lib/sops-nix/keys.txt` and add to `.sops.yaml`
6. Build and apply: `sudo nixos-rebuild switch --flake .#HOSTNAME`

### Adding a New Home Manager User
1. Create user directory: `secrets/users/new-user/`
2. Generate age key:
   - **Darwin**: `mkdir -p "$HOME/Library/Application Support/sops/age" && age-keygen -o "$HOME/Library/Application Support/sops/age/keys.txt"`
   - **Linux**: `mkdir -p /var/lib/sops-nix && age-keygen -o /var/lib/sops-nix/keys.txt`
3. Get public key: `age-keygen -y <path-to-keys.txt>` and add to `.sops.yaml`
4. Define user in `flake.nix` using `user.mkHMUser`
5. Build and apply: `./hm-apply.sh`

## Secrets Management with SOPS

### SOPS Integration
- **NixOS**: sops-nix module imported in core role with age key at `/var/lib/sops-nix/keys.txt`
- **Home Manager (Darwin)**: Age key at `~/Library/Application Support/sops/age/keys.txt`
- **Home Manager (Linux)**: Age key at `/var/lib/sops-nix/keys.txt`
- **Library**: Custom sops utilities available as `util.sops` in all roles

### Age Key Locations
- **NixOS System**: `/var/lib/sops-nix/keys.txt`
- **Home Manager (Darwin)**: `~/Library/Application Support/sops/age/keys.txt`
- **Home Manager (Linux)**: `/var/lib/sops-nix/keys.txt`

### Secret and Template File Locations

**Individual Secrets (decrypted)**:
- **NixOS**: `/run/secrets/{secret-name}`
- **Home Manager**: `~/.config/sops-nix/secrets/{secret-name}`

**Templates (rendered with actual values)**:
- **NixOS**: `/run/secrets/rendered/{template-name}`
- **Home Manager**: `~/.config/sops-nix/secrets/rendered/{template-name}`

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

# Darwin: Encrypt with specific age key
export SOPS_AGE_RECIPIENTS=age15szuax689kt40ftylqynggcn7fgxp6y8x7lrmk44htcjcu6yjqzs2p0l8e
sops -e -i secrets/users/username/new-secret.yaml
```

### Testing Templates
```bash
# Verify template content (should show placeholders, not actual secrets)
nix eval .#nixosConfigurations.hostname.config.sops.templates.template-name.content

# Templates should contain: <SOPS:hash:PLACEHOLDER>
```

### Verify Your SOPS Setup

#### 1. Check Age Key Location
```bash
# Darwin
ls -la "$HOME/Library/Application Support/sops/age/keys.txt"

# Linux (NixOS or home-manager)
ls -la /var/lib/sops-nix/keys.txt
```

#### 2. Get Your Public Key
```bash
# Darwin
age-keygen -y "$HOME/Library/Application Support/sops/age/keys.txt"

# Linux
age-keygen -y /var/lib/sops-nix/keys.txt
```

#### 3. Verify Key in .sops.yaml
Your public key must be listed in `.sops.yaml`:
```yaml
keys:
  - &yourname age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

#### 4. Test Decryption
```bash
# Try to decrypt a secret manually
sops -d secrets/users/USERNAME/secret.yaml

# If decryption fails, re-encrypt with correct keys
sops updatekeys secrets/users/USERNAME/secret.yaml
```

#### 5. Check Decrypted Secrets and Templates
```bash
# List all secrets (home-manager)
ls -la ~/.config/sops-nix/secrets/

# List all rendered templates
ls -la ~/.config/sops-nix/secrets/rendered/

# View a template (contains actual secret values!)
cat ~/.config/sops-nix/secrets/rendered/template-name
```

## Darwin-Specific Configuration

### SOPS Setup for Darwin
Darwin uses a different age key location and launchd service management:

1. **Age Key Generation**:

**Before generating a new key**, check if you already have one:
```bash
ls -la "$HOME/Library/Application Support/sops/age/keys.txt"
age-keygen -y "$HOME/Library/Application Support/sops/age/keys.txt"
```

**If you need to generate a new key**:

```bash
# 1. Generate the key
mkdir -p "$HOME/Library/Application Support/sops/age"
age-keygen -o "$HOME/Library/Application Support/sops/age/keys.txt"

# 2. Get your public key
age-keygen -y "$HOME/Library/Application Support/sops/age/keys.txt"
# Output: age1xxxxx...

# 3. Add the public key to .sops.yaml
# Edit .sops.yaml and add:
#   keys:
#     - &yourname age1xxxxx...

# 4. Re-encrypt all your secrets
find secrets/users/yourname -name "*.yaml" -exec sops updatekeys {} \;

# 5. Rebuild home-manager
./hm-apply.sh
```

2. **Service Management**:
```bash
# List sops-nix service
launchctl list | grep sops

# Check sops-nix service status
launchctl print gui/$(id -u)/org.nix-community.home.sops-nix

# Restart service after configuration changes
launchctl kickstart gui/$(id -u)/org.nix-community.home.sops-nix
```

3. **Template Verification**:
```bash
# Check if templates are rendered
ls -la ~/.config/sops-nix/secrets/rendered/

# View template content (contains actual secrets at runtime)
cat ~/.config/sops-nix/secrets/rendered/template-name
```

### Debugging SOPS on Darwin

#### Check Service Logs
```bash
# Check error logs (note: may contain old errors from previous builds)
cat ~/Library/Logs/SopsNix/stderr

# Watch logs in real-time
tail -f ~/Library/Logs/SopsNix/stderr
```

**Important**: Error logs may contain old failures from previous builds. Always verify actual secret files to confirm current status:
```bash
# Check if secrets are actually decrypted (these are the real files used at runtime)
ls -la ~/.config/sops-nix/secrets/
cat ~/.config/sops-nix/secrets/secret-name

# Check if templates are rendered
ls -la ~/.config/sops-nix/secrets/rendered/
cat ~/.config/sops-nix/secrets/rendered/template-name
```

#### Restart Service After Configuration Changes
```bash
# Rebuild home-manager config (automatically restarts sops-nix service)
./hm-apply.sh

# Or manually restart service
launchctl kickstart gui/$(id -u)/org.nix-community.home.sops-nix
```

### Common SOPS Errors and Solutions

#### "Error getting data key: 0 successful groups required, got 0"
**Cause**: Secret file was not encrypted with the age keys defined in `.sops.yaml`

**Solution**: Re-encrypt the secret with correct keys:
```bash
# Method 1: Update keys in-place (preserves values)
sops updatekeys secrets/users/USERNAME/secret.yaml

# Method 2: Re-edit with correct config
sops secrets/users/USERNAME/secret.yaml
```

**Prevention**: Always verify your public key is in `.sops.yaml` before encrypting:
```bash
# Get your public key
age-keygen -y "$HOME/Library/Application Support/sops/age/keys.txt"

# Check it exists in .sops.yaml
grep "age1xxxxx" .sops.yaml
```

#### Templates Not Rendered or Contain Placeholders at Runtime
**Cause**: sops-nix service not running or secrets not decrypted

**Solution**:
```bash
# Check if service is running (Darwin)
launchctl list | grep sops

# Restart service
launchctl kickstart gui/$(id -u)/org.nix-community.home.sops-nix

# Rebuild home-manager
./hm-apply.sh

# Verify templates are rendered
ls -la ~/.config/sops-nix/secrets/rendered/
```

#### Old Errors in Logs but Secrets Work
**Note**: Error logs in `~/Library/Logs/SopsNix/stderr` may contain old failures from previous builds. Always check the actual secret files to verify current status:
```bash
# Check actual decrypted secrets (these are what matter)
ls -la ~/.config/sops-nix/secrets/
cat ~/.config/sops-nix/secrets/secret-name
```

If the secret files exist and contain correct values, the system is working correctly regardless of old log entries.

### Darwin Role Configuration
The `roles/home-manager/core-apps/darwin/default.nix` role is specifically for Darwin machines and includes:
- Darwin-specific packages (colima, etc.)
- Shell aliases with SOPS template integration
- Platform-specific configurations

Example secure shell alias using SOPS templates:
```nix
programs.zsh.shellAliases = {
  myalias = "source ${config.sops.templates."env-file".path} && command --option=$SECRET_VAR";
};
```
