{ lib, config, pkgs, util, ... }:

# Clean API - secrets merged with other config
(util.sops.mkSecretsConfig [
  # Personal GitHub token (dynamically resolves to current user)
  (util.sops.userSecret "personal-github-token" "personal-github.yaml" "token")
  
  # Organization GitHub token (shared across all users)
  (util.sops.commonSecret "org-github-token" "github-org.yaml" "token")
  
  # Personal GitHub email (dynamically resolves to current user)  
  (util.sops.userSecret "github-email" "personal-github.yaml" "email")
] {

  # Example usage of the secrets in home-manager config
  home.packages = with pkgs; [
    # Package that might use secrets
    git
  ];

  # Example of using secrets in programs
  programs.git = {
    enable = true;
    extraConfig = {
      # In real usage, you'd reference: config.sops.secrets.github-token.path
      # For now, just show the concept
      credential.helper = "store";
    };
  };

  # Add a simple script that demonstrates secret access
  home.file."bin/test-secrets".text = ''
    #!/bin/sh
    echo "Testing sops secrets integration with encrypted files..."
    echo "Personal GitHub token: ${config.sops.secrets.personal-github-token.path or "not-configured"}"
    echo "Org GitHub token: ${config.sops.secrets.org-github-token.path or "not-configured"}"
    echo "GitHub email: ${config.sops.secrets.github-email.path or "not-configured"}"
    echo ""
    echo "Example usage:"
    echo "  cat \$HOME/.config/sops-nix/secrets/personal-github-token"
    echo "  export GITHUB_TOKEN=\$(cat \$HOME/.config/sops-nix/secrets/org-github-token)"
  '';
  
  home.file."bin/test-secrets".executable = true;
}) { inherit config lib; }