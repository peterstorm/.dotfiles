{ lib, config, pkgs, util, ... }:

# Example of SECURE template-based sops usage for home-manager - avoids nix store exposure
(util.sops.mkSecretsAndTemplatesConfig 
  # 1. Define secrets (these get decrypted to ~/.config/sops-nix/secrets/)
  [
    # Personal GitHub credentials
    (util.sops.userSecret "github-token" "personal-github.yaml" "token")
    (util.sops.userSecret "github-email" "personal-github.yaml" "email")
    
    # Organization token
    (util.sops.commonSecret "org-token" "github-org.yaml" "token")
    # Gemini API key
    (util.sops.userSecret "gemini-api-key" "gemini.yaml" "api_key")
  ]
  
  # 2. Define templates (these generate files with actual secret values)
  [
    # Environment file template for development
    (util.sops.envTemplate "dev-env" {
      GITHUB_EMAIL = "github-email";
      ORG_TOKEN = "org-token";
      GEMINI_API_KEY = "gemini-api-key";
    })
    
    # Git credentials template
    (util.sops.configTemplate "git-credentials" ''
      https://github.com
      	login=${config.sops.placeholder."github-token"}
      	password=${config.sops.placeholder."github-token"}
    '')
    
    # App config template
    (util.sops.configTemplate "app-config" ''
      {
        "github": {
          "token": "${config.sops.placeholder."github-token"}",
          "email": "${config.sops.placeholder."github-email"}",
          "org_token": "${config.sops.placeholder."org-token"}"
        }
      }
    '')
  ]
  
  # 3. Regular home-manager configuration that uses the templates
  {
    # Packages
    home.packages = with pkgs; [ git jq ];

    # Script that demonstrates secure template usage
    home.file."bin/test-secure-secrets".text = ''
      #!/bin/sh
      echo "Testing SECURE sops templates (secrets not in nix store)..."
      echo ""
      echo "Template files generated with actual secret values:"
      echo "  Dev env: ${config.sops.templates."dev-env".path}"
      echo "  Git creds: ${config.sops.templates."git-credentials".path}" 
      echo "  App config: ${config.sops.templates."app-config".path}"
      echo ""
      echo "Example usage:"
      echo "  source ${config.sops.templates."dev-env".path}"
      echo "  git config credential.helper 'store --file=${config.sops.templates."git-credentials".path}'"
      echo "  cat ${config.sops.templates."app-config".path} | jq '.github.email'"
      echo ""
      echo "These template files contain the actual secret values!"
      echo "The secrets are NOT exposed in the nix store."
    '';
    home.file."bin/test-secure-secrets".executable = true;

    # Source dev-env (includes GEMINI_API_KEY, GitHub tokens) on shell init
    programs.bash.initExtra = ''
      source ${config.sops.templates."dev-env".path}
    '';

    # Git configuration using the template
    programs.git = {
      enable = true;
      extraConfig = {
        # Use the credential file template (contains actual secrets)
        credential.helper = "store --file=${config.sops.templates."git-credentials".path}";
      };
    };
  }
) { inherit config lib; }