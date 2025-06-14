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

## Using Secrets in Roles

### Simple API (Recommended)

Use `util.sops.mkSecretsConfig` for the cleanest experience:

```nix
{ lib, config, pkgs, util, ... }:

# Clean API - secrets + other config in one call
(util.sops.mkSecretsConfig [
  # Dynamic resolution - automatically uses current user/host
  (util.sops.userSecret "github-token" "github.yaml" "token")
  (util.sops.hostSecret "api-key" "api.yaml" "key")
  (util.sops.commonSecret "shared-token" "shared.yaml" "token")
] {
  # Your regular NixOS/home-manager configuration
  home.packages = [ pkgs.git ];
  
  programs.git = {
    enable = true;
    extraConfig = {
      # Access secrets via config.sops.secrets.NAME.path
      credential.helper = "!f() { echo username=$(cat ${config.sops.secrets.github-token.path}); }; f";
    };
  };
}) { inherit config lib; }
```

### Dynamic Resolution Helpers

The library provides helpers that automatically resolve paths based on current context:

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

### Manual Path Configuration

For more control, use explicit paths:
```nix
(util.sops.mkSecretsConfig [
  {
    name = "custom-secret";
    file = "secrets/specific/path/file.yaml";
    key = "my_key";
    owner = "nginx";
    group = "nginx";
    mode = "0440";
  }
] {
  # other config
}) { inherit config lib; }
```

### Environment Files

For `.env` format files:
```nix
(util.sops.mkSecretsConfig [
  (util.sops.userEnvFile "env-secrets" "app.env")
  (util.sops.hostEnvFile "host-env" "system.env")
] {
  # other config
}) { inherit config lib; }
```

## Real Examples

### Home Manager Role (`roles/home-manager/my-app/default.nix`)
```nix
{ lib, config, pkgs, util, ... }:

(util.sops.mkSecretsConfig [
  # Personal GitHub credentials
  (util.sops.userSecret "github-token" "github.yaml" "token")
  (util.sops.userSecret "github-email" "github.yaml" "email")
  
  # Shared organization token
  (util.sops.commonSecret "org-token" "github-org.yaml" "token")
] {

  programs.git = {
    enable = true;
    userEmail = "${config.home.username}@example.com";
    extraConfig = {
      credential.helper = "store";
    };
  };
  
  # Create a script that uses the secrets
  home.file."bin/github-setup".text = ''
    #!/bin/sh
    export GITHUB_TOKEN=$(cat ${config.sops.secrets.github-token.path})
    export ORG_TOKEN=$(cat ${config.sops.secrets.org-token.path})
    # Use tokens...
  '';
  home.file."bin/github-setup".executable = true;
  
}) { inherit config lib; }
```

### NixOS Role (`roles/my-service/default.nix`)
```nix
{ lib, config, pkgs, util, ... }:

(util.sops.mkSecretsConfig [
  # Host-specific API credentials
  (util.sops.hostSecret "api-key" "service.yaml" "api_key" {
    owner = "myservice";
    group = "myservice";
    mode = "0400";
  })
  
  # Database password
  (util.sops.hostSecret "db-password" "service.yaml" "db_password" {
    owner = "postgres";
    group = "postgres";
    mode = "0400";
  })
] {

  # Create service user
  users.users.myservice = {
    isSystemUser = true;
    group = "myservice";
  };
  users.groups.myservice = {};

  # Configure systemd service
  systemd.services.myservice = {
    description = "My Service";
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "simple";
      User = "myservice";
      Group = "myservice";
      ExecStart = "${pkgs.writeShellScript "myservice" ''
        export API_KEY=$(cat ${config.sops.secrets.api-key.path})
        export DB_PASS=$(cat ${config.sops.secrets.db-password.path})
        ${pkgs.myservice}/bin/myservice
      ''}";
    };
  };
  
}) { inherit config lib; }
```

## Secret Access

Once configured, secrets are available at:
- **NixOS**: `/run/secrets/{secret-name}`
- **Home Manager**: `~/.config/sops-nix/secrets/{secret-name}`

Access in configuration via: `config.sops.secrets.{secret-name}.path`

## File Permissions

Default permissions:
- **Files**: `0400` (owner read-only)
- **Owner**: Automatically determined by context
  - Home Manager: Current user
  - NixOS: `root` (unless specified)

Override with custom attributes:
```nix
(util.sops.hostSecret "secret" "file.yaml" "key" {
  owner = "nginx";
  group = "nginx"; 
  mode = "0440";
})
```

## Migration from Old API

**Old (verbose):**
```nix
lib.recursiveUpdate 
  (util.sops.mkSecrets [...] { inherit config; })
  { /* other config */ }
```

**New (clean):**
```nix
(util.sops.mkSecretsConfig [...] {
  /* other config */
}) { inherit config lib; }
```

## Troubleshooting

1. **Secret not found**: Verify the file path matches your directory structure
2. **Permission denied**: Check file ownership and mode settings
3. **Decryption failed**: Ensure your age key is properly configured
4. **Build errors**: Make sure to `git add` new secret files before building

## Security Best Practices

- Never commit unencrypted secrets to git
- Use appropriate file permissions (prefer `0400` or `0440`)
- Separate secrets by scope (user vs host vs common)
- Regularly rotate sensitive credentials
- Use dedicated service users for system secrets