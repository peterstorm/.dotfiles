# SOPS Guide for Dotfiles Repository

This guide shows you how to securely manage secrets in your NixOS/Home Manager dotfiles using SOPS templates - the only secure way to handle secrets in Nix.

## Understanding Your Current Setup

Your repository already has SOPS partially configured:

- **SOPS input**: `sops-nix` is declared in `flake.nix`
- **Core integration**: `roles/core/default.nix` imports the sops-nix module
- **Custom secrets module**: `modules/secrets/default.nix` handles secret configuration
- **Age encryption**: `.sops.yaml` configures your age key for encryption
- **Host-specific secrets**: Files like `secrets/laptop-xps.yaml` contain encrypted secrets

**Currently enabled on**: Only `laptop-xps` has `sopsSecrets = true`

## ⚠️ Critical Security Principle

**NEVER interpolate secrets directly in Nix expressions!** This would embed secrets in the world-readable Nix store.

```nix
# ❌ NEVER DO THIS - INSECURE!
programs.git.extraConfig = {
  github.token = config.sops.secrets.github_token.path;  # This embeds the file path, not secret!
};

# ✅ USE TEMPLATES INSTEAD - SECURE!
sops.templates."gitconfig".content = ''
  [github]
    token = ${config.sops.secrets.github_token.path}
'';
```

## Step-by-Step Implementation Guide

### 1. Enable SOPS for Your Hosts

Edit your host configurations in `flake.nix` to enable SOPS:

```nix
# Add sopsSecrets = true; to any host that needs secrets
laptop-work = host.mkHost {
  name = "laptop-work";
  roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" ];
  machine = [ "laptop-work" ];
  # ... other config ...
  sopsSecrets = true;  # Add this line
};
```

### 2. Create Secret Files for Each Host

Create encrypted secret files for each host:

```bash
# Create secrets file for laptop-work
cp secrets/example.yaml secrets/laptop-work.yaml

# Edit the new secrets file
sops secrets/laptop-work.yaml
```

### 3. Add Your Secrets

In the SOPS editor, replace the example content with your actual secrets:

```yaml
# secrets/laptop-work.yaml (when decrypted)
github_token: "ghp_your_actual_token_here"
work_ssh_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  your_actual_ssh_key_content_here
  -----END OPENSSH PRIVATE KEY-----
work_email: "your.work@company.com"
npm_token: "npm_your_actual_token_here"
aws_access_key: "AKIA..."
aws_secret_key: "your_aws_secret_here"
```

### 4. Configure Secrets in Your Custom Module

Update `modules/secrets/default.nix` to define your secrets and templates:

```nix
{ config, lib, pkgs, ... }:
with lib;

let cfg = config.custom.secrets;

in {
  options.custom.secrets = {
    enable = mkEnableOption "enable sops-nix secrets file";
  };

  config = mkIf cfg.enable {
    sops.defaultSopsFile = ./../../secrets + "/${config.networking.hostName}.yaml";
    sops.age.keyFile = "/var/lib/sops-nix/keys.txt";
    
    # Define your secrets
    sops.secrets.github_token = {
      mode = "0400";
      owner = config.users.users.peterstorm.name;
    };
    sops.secrets.work_ssh_key = {
      mode = "0600";
      owner = config.users.users.peterstorm.name;
    };
    sops.secrets.work_email = {
      mode = "0400";
      owner = config.users.users.peterstorm.name;
    };
    sops.secrets.npm_token = {
      mode = "0400";
      owner = config.users.users.peterstorm.name;
    };
    sops.secrets.aws_access_key = {
      mode = "0400";
      owner = config.users.users.peterstorm.name;
    };
    sops.secrets.aws_secret_key = {
      mode = "0400";
      owner = config.users.users.peterstorm.name;
    };

    # Create secure templates that inject secrets at runtime
    sops.templates."gitconfig-work" = {
      content = ''
        [user]
          email = ${config.sops.secrets.work_email.path}
        [github]
          token = ${config.sops.secrets.github_token.path}
        [credential "https://github.com"]
          helper = store
      '';
      path = "/home/peterstorm/.gitconfig-work";
      mode = "0600";
      owner = config.users.users.peterstorm.name;
    };

    sops.templates."ssh-work-key" = {
      content = config.sops.secrets.work_ssh_key.path;
      path = "/home/peterstorm/.ssh/work_key";
      mode = "0600";
      owner = config.users.users.peterstorm.name;
    };

    sops.templates."ssh-config-work" = {
      content = ''
        Host github-work
          HostName github.com
          User git
          IdentityFile /home/peterstorm/.ssh/work_key
          IdentitiesOnly yes
      '';
      path = "/home/peterstorm/.ssh/config-work";
      mode = "0600";
      owner = config.users.users.peterstorm.name;
    };

    sops.templates."npmrc-work" = {
      content = ''
        @company:registry=https://npm.company.com/
        //npm.company.com/:_authToken=${config.sops.secrets.npm_token.path}
      '';
      path = "/home/peterstorm/.npmrc-work";
      mode = "0600";
      owner = config.users.users.peterstorm.name;
    };

    sops.templates."aws-credentials" = {
      content = ''
        [default]
        aws_access_key_id = ${config.sops.secrets.aws_access_key.path}
        aws_secret_access_key = ${config.sops.secrets.aws_secret_key.path}
      '';
      path = "/home/peterstorm/.aws/credentials";
      mode = "0600";
      owner = config.users.users.peterstorm.name;
    };
  };
}
```

### 5. Set Up Your Age Key

Your age key needs to be accessible to SOPS. On each machine:

```bash
# Copy your age key to the expected location
sudo mkdir -p /var/lib/sops-nix
sudo cp ~/.config/sops/age/keys.txt /var/lib/sops-nix/keys.txt
sudo chown root:root /var/lib/sops-nix/keys.txt
sudo chmod 600 /var/lib/sops-nix/keys.txt
```

### 6. Deploy Your Configuration

Apply your configuration:

```bash
./system-apply.sh
```

## Common Usage Patterns

### Git Credentials
After deployment, your work git credentials are automatically available:
```bash
# Git operations with work credentials work automatically
git clone git@github-work:company/private-repo.git

# Or include the work config
git config --file ~/.gitconfig-work user.email
```

### SSH Keys
```bash
# SSH with work keys
ssh -F ~/.ssh/config-work github-work

# Or add to your main SSH config:
echo "Include ~/.ssh/config-work" >> ~/.ssh/config
```

### NPM Authentication
```bash
# Use work npmrc for private packages
npm install --userconfig ~/.npmrc-work @company/private-package
```

### AWS CLI
```bash
# AWS credentials are automatically available
aws s3 ls  # Uses credentials from ~/.aws/credentials
```

## Adding New Secrets

### 1. Add to Secrets File
```bash
sops secrets/laptop-xps.yaml
# Add your new secret in the editor
```

### 2. Define in Secrets Module
```nix
# Add to modules/secrets/default.nix
sops.secrets.new_secret = {
  mode = "0400";
  owner = config.users.users.peterstorm.name;
};
```

### 3. Create Template (if needed)
```nix
sops.templates."new-config" = {
  content = ''
    api_key = ${config.sops.secrets.new_secret.path}
  '';
  path = "/home/peterstorm/.config/app/config";
  mode = "0600";
  owner = config.users.users.peterstorm.name;
};
```

### 4. Apply Changes
```bash
./system-apply.sh
```

## Per-Machine Secret Management

Each host automatically uses its own secrets file:
- `laptop-xps` → `secrets/laptop-xps.yaml`
- `laptop-work` → `secrets/laptop-work.yaml`
- `desktop` → `secrets/desktop.yaml`

This allows different secrets per machine while using the same configuration structure.

## Home Manager Integration

To use secrets in Home Manager configurations, create a role that references the template files:

```nix
# roles/home-manager/work-secrets/default.nix
{ config, lib, pkgs, ... }:

{
  # Reference the template files created by the system configuration
  programs.git.includes = [
    { path = "~/.gitconfig-work"; }
  ];
  
  programs.ssh.includes = [
    "~/.ssh/config-work"
  ];
}
```

Then add the role to your Home Manager user:
```nix
peterstorm = user.mkHMUser {
  roles = [ "core-apps" "window-manager/xmonad" "dunst" "games" "work-secrets" ];
  username = "peterstorm";
};
```

## Security Best Practices

1. **Always use templates** - Never interpolate secrets directly
2. **Restrictive permissions** - Use `mode = "0600"` or `mode = "0400"`
3. **Proper ownership** - Set `owner` to the correct user
4. **Separate secrets per host** - Different machines, different secret files
5. **Version control secrets safely** - Encrypted files are safe to commit
6. **Backup your age key** - Store it securely outside the repository

## Troubleshooting

### Age Key Not Found
```bash
# Check if age key exists
ls -la /var/lib/sops-nix/keys.txt

# If missing, copy from your user directory
sudo cp ~/.config/sops/age/keys.txt /var/lib/sops-nix/keys.txt
sudo chmod 600 /var/lib/sops-nix/keys.txt
```

### Permission Denied
```bash
# Check secret file permissions
ls -la /run/secrets/

# Check template file permissions
ls -la ~/.gitconfig-work ~/.ssh/work_key
```

### Secrets Not Updating
After editing secrets files:
```bash
# Restart sops-nix service
sudo systemctl restart sops-nix

# Or rebuild system
./system-apply.sh
```

## Migration from Existing Secrets

If you have existing secrets stored elsewhere:

```bash
# Edit your secrets file
sops secrets/$(hostname).yaml

# In the editor, add your existing secrets
# They'll be automatically encrypted when you save
```

This approach gives you declarative, secure secret management that integrates perfectly with your existing NixOS configuration architecture.