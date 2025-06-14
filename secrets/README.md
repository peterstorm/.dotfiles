# Secrets Management with SOPS

This directory contains encrypted secrets using [SOPS](https://github.com/getsops/sops) (Secrets OPerationS) with Age encryption. The secrets are automatically decrypted and made available to NixOS and home-manager configurations.

## Directory Structure

```
secrets/
├── common/          # Shared across all hosts/users
│   └── github-org.yaml
├── hosts/{hostname}/ # Host-specific secrets (NixOS)
│   ├── homelab/
│   │   └── cloudflare.yaml
│   └── laptop-xps/
│       └── example.yaml
└── users/{username}/ # User-specific secrets (home-manager)
    └── peterstorm/
        └── personal-github.yaml
```

## Supported File Formats
- **`.yaml`** - Key-value secrets (most common)
- **`.env`** - Environment file format  
- **`.json`** - JSON format
- **`.txt`** - Plain text (for single values)

## Creating and Encrypting Secrets

### 1. Create a new secret file
```bash
# Create the directory structure
mkdir -p secrets/users/myuser

# Create unencrypted YAML file
cat > secrets/users/myuser/github.yaml << EOF
token: ghp_my_github_token_123
email: user@example.com
username: myuser
EOF
```

### 2. Encrypt with SOPS
```bash
# Encrypt the file in place
sops -e -i secrets/users/myuser/github.yaml

# Or edit an existing encrypted file
sops secrets/users/myuser/github.yaml
```

### 3. Verify encryption
```bash
# File should now contain encrypted content
cat secrets/users/myuser/github.yaml
# Shows: token: ENC[AES256_GCM,data:...,iv:...,tag:...,type:str]
```

## APIs Available

We provide two APIs for using secrets:

### 🚨 Legacy API (Secrets in Nix Store - Less Secure)
Direct secret access - secrets may be exposed in `/nix/store/` 

### ✅ Template API (Recommended - Secure)  
Template-based approach - secrets are **never** in the Nix store

---

# Template-Based API (Recommended)

## Why Templates?

Templates solve a critical security issue: **secrets never enter the Nix store**.

### The Problem with Direct Secrets
```nix
# ❌ INSECURE: This puts secrets in /nix/store/!
programs.git.extraConfig = {
  token = "${config.sops.secrets.github-token.path}";  # Nix evaluates this!
};
```

### The Template Solution
```nix
# ✅ SECURE: Templates use placeholders, secrets only exist at runtime
sops.templates."app-config".content = ''
  token = ${config.sops.placeholder."github-token"}  # Placeholder, not actual secret
'';
```

## How Templates Work

1. **Build time**: Only encrypted files and placeholder templates in Nix store ✅
2. **Runtime**: sops-nix renders templates with actual secret values ✅
3. **Result**: Secrets only exist in generated files with proper permissions ✅

## Template API Usage

### Basic Template Configuration

```nix
{ lib, config, pkgs, util, ... }:

(util.sops.mkSecretsAndTemplatesConfig
  # 1. Define secrets (individual decrypted files)
  [
    (util.sops.userSecret "github-token" "github.yaml" "token")
    (util.sops.userSecret "github-email" "github.yaml" "email") 
    (util.sops.commonSecret "org-token" "github-org.yaml" "token")
  ]
  
  # 2. Define templates (rendered config files)
  [
    # Environment file template
    (util.sops.envTemplate "dev-env" {
      GITHUB_TOKEN = "github-token";
      GITHUB_EMAIL = "github-email";
      ORG_TOKEN = "org-token";
    })
    
    # JSON config template
    (util.sops.configTemplate "app-config" ''
      {
        "github": {
          "token": "${config.sops.placeholder."github-token"}",
          "email": "${config.sops.placeholder."github-email"}"
        }
      }
    '')
  ]
  
  # 3. Regular configuration
  {
    home.packages = [ pkgs.git pkgs.jq ];
  }
) { inherit config lib; }
```

### Template Helpers

#### Environment File Templates
Creates `.env` files with secret values:
```nix
(util.sops.envTemplate "my-app-env" {
  API_KEY = "api-secret";      # References sops.secrets.api-secret  
  DB_PASS = "database-password"; # References sops.secrets.database-password
})
```

Generates:
```bash
# /run/secrets/rendered/my-app-env (home-manager: ~/.config/sops-nix/secrets/rendered/my-app-env)
API_KEY=actual_secret_value_here
DB_PASS=actual_password_here
```

#### Config File Templates
Creates configuration files with secret substitution:
```nix
(util.sops.configTemplate "nginx-config" ''
  server {
    ssl_certificate ${config.sops.placeholder."ssl-cert"};
    ssl_certificate_key ${config.sops.placeholder."ssl-key"};
  }
'')
```

## Home Manager Template Example

```nix
{ lib, config, pkgs, util, ... }:

(util.sops.mkSecretsAndTemplatesConfig 
  # Secrets
  [
    (util.sops.userSecret "github-token" "personal-github.yaml" "token")
    (util.sops.userSecret "ssh-key" "personal-github.yaml" "ssh_key")
    (util.sops.commonSecret "company-vpn" "company.yaml" "vpn_key")
  ]
  
  # Templates  
  [
    # Development environment
    (util.sops.envTemplate "dev-env" {
      GITHUB_TOKEN = "github-token";
      SSH_KEY_PATH = "ssh-key";
    })
    
    # Git credentials file
    (util.sops.configTemplate "git-credentials" ''
      https://github.com
      	login=${config.sops.placeholder."github-token"}
      	password=${config.sops.placeholder."github-token"}
    '')
    
    # SSH config with secrets
    (util.sops.configTemplate "ssh-config" ''
      Host github.com
        IdentityFile ${config.sops.placeholder."ssh-key"}
        User git
    '')
  ]
  
  # Configuration
  {
    programs.git = {
      enable = true;
      extraConfig = {
        # Use rendered template file (contains actual secrets)
        credential.helper = "store --file=${config.sops.templates."git-credentials".path}";
      };
    };
    
    # Script that uses environment template
    home.file."bin/dev-setup".text = ''
      #!/bin/sh
      # Source the rendered environment file
      source ${config.sops.templates."dev-env".path}
      
      # Now GITHUB_TOKEN is available as environment variable
      gh auth login --with-token <<< "$GITHUB_TOKEN"
    '';
    home.file."bin/dev-setup".executable = true;
  }
) { inherit config lib; }
```

## NixOS Template Example

```nix
{ lib, config, pkgs, util, ... }:

(util.sops.mkSecretsAndTemplatesConfig
  # Secrets
  [
    (util.sops.hostSecret "api-key" "service.yaml" "api_key" {
      owner = "myservice";
      group = "myservice";
    })
    (util.sops.hostSecret "db-password" "service.yaml" "db_password" {
      owner = "myservice"; 
      group = "myservice";
    })
    (util.sops.hostSecret "ssl-cert" "ssl.yaml" "certificate" {
      owner = "nginx";
      group = "nginx";
    })
  ]
  
  # Templates
  [
    # Service environment file
    (util.sops.envTemplate "myservice-env" {
      API_KEY = "api-key";
      DATABASE_PASSWORD = "db-password";
    })
    
    # Nginx configuration
    (util.sops.configTemplate "nginx-ssl-config" ''
      server {
        listen 443 ssl;
        ssl_certificate ${config.sops.placeholder."ssl-cert"};
        
        location /api {
          proxy_pass http://localhost:8080;
          proxy_set_header Authorization "Bearer ${config.sops.placeholder."api-key"}";
        }
      }
    '')
  ]
  
  # Configuration
  {
    users.users.myservice = {
      isSystemUser = true;
      group = "myservice";
    };
    users.groups.myservice = {};

    systemd.services.myservice = {
      description = "My Service with Secure Templates";
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "simple";
        User = "myservice";
        Group = "myservice";
        # Use the rendered environment file
        EnvironmentFile = config.sops.templates."myservice-env".path;
        ExecStart = "${pkgs.myservice}/bin/myservice";
      };
    };
    
    services.nginx = {
      enable = true;
      # Include the rendered nginx config (contains actual SSL cert path)
      appendConfig = builtins.readFile config.sops.templates."nginx-ssl-config".path;
    };
  }
) { inherit config lib; }
```

## Template File Locations

Templates generate files at:
- **NixOS**: `/run/secrets/rendered/{template-name}`
- **Home Manager**: `~/.config/sops-nix/secrets/rendered/{template-name}`

Access via: `config.sops.templates."{template-name}".path`

## Template Security Benefits

✅ **Secrets never in Nix store**
```bash
$ grep -r "actual_secret" /nix/store/  # No results!
```

✅ **Proper file permissions**
```bash
$ ls -la ~/.config/sops-nix/secrets/rendered/
-r-------- 1 user users 123 dev-env
-r-------- 1 user users 456 app-config
```

✅ **Runtime-only secret access**
```bash
$ cat ~/.config/sops-nix/secrets/rendered/dev-env
GITHUB_TOKEN=ghp_actual_secret_here  # Only exists at runtime!
```

---

# Legacy API (Less Secure)

## Direct Secret Access

⚠️ **Warning**: This approach may expose secrets in the Nix store. Use only when templates are not suitable.

### Basic Usage

```nix
{ lib, config, pkgs, util, ... }:

(util.sops.mkSecretsConfig [
  (util.sops.userSecret "github-token" "github.yaml" "token")
  (util.sops.hostSecret "api-key" "api.yaml" "key")
] {
  # Access secrets via file paths
  home.file."script.sh".text = ''
    #!/bin/sh
    export TOKEN=$(cat ${config.sops.secrets.github-token.path})
  '';
}) { inherit config lib; }
```

### Dynamic Resolution Helpers

#### User Secrets (`userSecret`)
Resolves to `secrets/users/{current-username}/filename`
```nix
(util.sops.userSecret "secret-name" "filename.yaml" "key-name")
```

#### Host Secrets (`hostSecret`) 
Resolves to `secrets/hosts/{current-hostname}/filename`
```nix
(util.sops.hostSecret "secret-name" "filename.yaml" "key-name" {
  owner = "root";
  group = "root";
  mode = "0400";
})
```

#### Common Secrets (`commonSecret`)
Resolves to `secrets/common/filename`
```nix
(util.sops.commonSecret "secret-name" "filename.yaml" "key-name")
```

---

# Migration Guide

## From Legacy to Templates

**Before (legacy)**:
```nix
(util.sops.mkSecretsConfig [
  (util.sops.userSecret "github-token" "github.yaml" "token")
] {
  home.file."script.sh".text = ''
    export TOKEN=$(cat ${config.sops.secrets.github-token.path})
  '';
}) { inherit config lib; }
```

**After (secure templates)**:
```nix
(util.sops.mkSecretsAndTemplatesConfig 
  [(util.sops.userSecret "github-token" "github.yaml" "token")]
  [(util.sops.envTemplate "app-env" { TOKEN = "github-token"; })]
  {
    home.file."script.sh".text = ''
      source ${config.sops.templates."app-env".path}
      # TOKEN is now available as environment variable
    '';
  }
) { inherit config lib; }
```

## Testing Template Configuration

### Quick Evaluation Test
Before building, verify templates evaluate correctly:
```bash
# Test template content (should show placeholders, not actual secrets)
nix eval .#nixosConfigurations.hostname.config.sops.templates.template-name.content

# Test template path resolution
nix eval .#homeManagerConfigurations.username.config.sops.templates.template-name.path
```

### Verify Security (No Secrets in Nix Store)
```bash
# Should return no results - templates use placeholders only
nix eval .#nixosConfigurations.hostname.config.sops.templates.template-name.content | grep "actual_secret_value"

# Templates should contain sops placeholders like: <SOPS:hash:PLACEHOLDER>
```

## Troubleshooting

1. **Template not found**: Check that template name matches between definition and usage
2. **Permission denied**: Verify secret ownership matches template usage context  
3. **Placeholder not substituted**: Ensure secret name in placeholder matches secret definition
4. **Build errors**: Run `git add .` to include new secret files before building
5. **Template shows placeholders**: This is correct! Actual values only appear at activation time
6. **Long NixOS builds**: Use `nix eval` to test template configuration before full builds

## Security Best Practices

### 🔒 Always Use Templates When Possible
- Templates ensure secrets never enter the Nix store
- Use legacy API only for edge cases where templates don't work

### 🔑 Proper Secret Organization  
- User-specific: `secrets/users/{username}/`
- Host-specific: `secrets/hosts/{hostname}/`
- Shared: `secrets/common/`

### 🛡️ File Permissions
- Secrets: `0400` (owner read-only)
- Templates: `0400` (owner read-only) 
- Use dedicated service users for system secrets

### 🔄 Operational Security
- Never commit unencrypted secrets to git
- Regularly rotate sensitive credentials  
- Monitor secret access patterns
- Use separate keys per environment/host when possible