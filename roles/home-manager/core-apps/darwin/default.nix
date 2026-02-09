{pkgs, config, lib, util, inputs, ...}:

(util.sops.mkSecretsAndTemplatesConfig
  # Define secrets
  [
    (util.sops.userSecret "oc-dev-server" "openshift.yaml" "dev_server")
    (util.sops.userSecret "oc-stage-server" "openshift.yaml" "stage_server")
    (util.sops.userSecret "oc-prod-server" "openshift.yaml" "prod_server")
    (util.sops.userSecret "flexii-db-password" "db_secrets.yaml" "flexii_database_password")
    (util.sops.userSecret "oister-db-password" "db_secrets.yaml" "oister_database_password")
    (util.sops.userSecret "keycloak-client-secret" "keycloak.yaml" "keycloak_client_secret")
  ]
  
  # Define templates
  [
    (util.sops.envTemplate "openshift-env" {
      OC_DEV_SERVER = "oc-dev-server";
      OC_STAGE_SERVER = "oc-stage-server";
      OC_PROD_SERVER = "oc-prod-server";
    })
    (util.sops.envTemplate "db-env" {
      FLEXII_DATABASE_PASSWORD = "flexii-db-password";
      OISTER_DATABASE_PASSWORD = "oister-db-password";
      KEYCLOAK_CLIENT_SECRET = "keycloak-client-secret";
    })
  ]
  
  # Configuration
  {
    # Fix: sops-nix launchd agent needs /usr/bin in PATH for getconf
    launchd.agents.sops-nix.config.EnvironmentVariables.PATH = lib.mkForce "/usr/bin:/bin:/usr/sbin:/sbin";

    home.packages = with pkgs;[
      wget
      openshift
      kubectl
      discord
      ripgrep
      inputs.llm-agents.packages.${pkgs.system}.claude-code
      gh
      git
      podman-compose
      postman
      bruno
      bytecode-viewer
      azure-cli
      kubeseal
      gemini-cli
      inputs.llm-agents.packages.${pkgs.system}.copilot-cli
      jq
      bun
      inputs.llm-agents.packages.${pkgs.system}.opencode
      inputs.llm-agents.packages.${pkgs.system}.codex
    ];

    programs.zsh = {
      enable = true;
      shellAliases = {
        ocdev = "source ${config.sops.templates."openshift-env".path} && oc login --web --server=$OC_DEV_SERVER --insecure-skip-tls-verify";
        ocstage = "source ${config.sops.templates."openshift-env".path} && oc login --web --server=$OC_STAGE_SERVER --insecure-skip-tls-verify";
        ocprod = "source ${config.sops.templates."openshift-env".path} && oc login --web --server=$OC_PROD_SERVER --insecure-skip-tls-verify";
        # Add your custom aliases here
      };
      initContent = ''
        # Source database environment variables
        source ${config.sops.templates."db-env".path}

        seal() {
          kubeseal --controller-namespace=sealed-secrets --format=yaml -o yaml < "$1" > "$2"
        }
      '';
    };
  }
) { inherit config lib; }

