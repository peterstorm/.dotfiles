# Secrets Organization

This directory contains encrypted secrets organized by scope:

## Structure
- `common/` - Secrets shared across all hosts/users
- `hosts/{hostname}/` - Host-specific secrets (system-level)
- `users/{username}/` - User-specific secrets (home-manager)

## Examples
- `common/github-org.yaml` - Organization GitHub token
- `hosts/homelab/cloudflare.yaml` - Homelab cloudflare credentials
- `users/peterstorm/personal-github.yaml` - Personal GitHub token

## File Formats
- `.yaml` - Key-value secrets (most common)
- `.env` - Environment file format
- `.json` - JSON format
- `.txt` - Plain text (for single values)

## Usage in Roles
```nix
util.sops.mkSecrets [
  { name = "github-token"; file = "secrets/users/peterstorm/github.yaml"; key = "token"; }
  { name = "cloudflare-key"; file = "secrets/hosts/homelab/cloudflare.yaml"; key = "api_key"; }
] { inherit config; }
```