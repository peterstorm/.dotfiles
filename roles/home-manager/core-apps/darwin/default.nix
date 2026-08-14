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
    (util.sops.userSecret "azure-client-secret" "keycloak.yaml" "azure_client_secret")
    (util.sops.userSecret "keycloak-admin-password-onr" "keycloak.yaml" "keycloak_admin_password_onr")
    (util.sops.userSecret "keycloak-admin-password-opr" "keycloak.yaml" "keycloak_admin_password_opr")
    (util.sops.userSecret "gemini-api-key" "gemini.yaml" "api_key")
    (util.sops.userSecret "cf-access-vllm-id" "cloudflare-access.yaml" "vllm_client_id")
    (util.sops.userSecret "cf-access-vllm-secret" "cloudflare-access.yaml" "vllm_client_secret")
    (util.sops.userSecret "vllm-api-key" "cloudflare-access.yaml" "vllm_api_key")
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
      AZURE_CLIENT_SECRET = "azure-client-secret";
      KEYCLOAK_ADMIN_PASSWORD_ONR = "keycloak-admin-password-onr";
      KEYCLOAK_ADMIN_PASSWORD_OPR = "keycloak-admin-password-opr";
    })
    (util.sops.envTemplate "gemini-env" {
      GEMINI_API_KEY = "gemini-api-key";
    })
    (util.sops.envTemplate "cf-access-env" {
      CF_ACCESS_CLIENT_ID = "cf-access-vllm-id";
      CF_ACCESS_CLIENT_SECRET = "cf-access-vllm-secret";
    })
    # OpenAI-compatible client env: with `vllm-forward` running, any client
    # (claude, opencode, curl, ...) works with zero flags.
    (util.sops.configTemplate "vllm-env" ''
      export OPENAI_API_KEY='${config.sops.placeholder."vllm-api-key"}'
      export OPENAI_BASE_URL='http://localhost:8000/v1'
    '')
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
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
      gh
      git
      podman-compose
      podman
      postman
      bruno
      bytecode-viewer
      firefox
      kubeseal
      jq
      bun
      inputs.loom-tui.packages.${pkgs.system}.default

      # Reaching the homelab from this machine. The corporate Cisco Secure
      # Client runs tunnel-all and claims 192.168.0.0/24 outright, so the LAN is
      # unreachable here even when sitting on the home network — a second
      # layer-3 tunnel would just lose the same routing-table fight, and this
      # account has no admin rights to install one anyway. cloudflared sidesteps
      # both: a userspace process speaking HTTPS out through whatever tunnel is
      # up, with no route, no interface and no privilege of its own.
      cloudflared

      # Access-authenticated port forward to the vLLM inference API on
      # `desktop`. Usage: `vllm-forward` (or `vllm-forward 9000` for a different
      # local port), then point any OpenAI-compatible client at
      # http://localhost:8000/v1 — no proxy awareness needed on the client side.
      #
      # The service token comes from sops rather than the shell environment so
      # it is never in scrollback or shell history.
      (writeShellScriptBin "vllm-forward" ''
        set -euo pipefail
        port="''${1:-8000}"
        source ${config.sops.templates."cf-access-env".path}
        echo "vLLM -> http://localhost:$port/v1   (ctrl-c to stop)" >&2
        exec ${cloudflared}/bin/cloudflared access tcp \
          --hostname vllm-tcp.peterstorm.io \
          --url "localhost:$port" \
          --service-token-id "$CF_ACCESS_CLIENT_ID" \
          --service-token-secret "$CF_ACCESS_CLIENT_SECRET"
      '')

    ];

    programs.bash.initExtra = ''
      source ${config.sops.templates."gemini-env".path}
      source ${config.sops.templates."vllm-env".path}
    '';

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
        source ${config.sops.templates."gemini-env".path}
        source ${config.sops.templates."vllm-env".path}

        # GitHub token for Maven/GitHub Packages authentication
        export GITHUB_TOKEN=$(gh auth token 2>/dev/null)

        seal() {
          kubeseal --controller-namespace=sealed-secrets --format=yaml -o yaml < "$1" > "$2"
        }
      '';
    };
  }
) { inherit config lib; }

