{pkgs, config, lib, util, ...}:

(util.sops.mkSecretsAndTemplatesConfig
  # Define secrets
  [
    (util.sops.userSecret "oc-dev-server" "openshift.yaml" "dev_server")
    (util.sops.userSecret "oc-stage-server" "openshift.yaml" "stage_server")
    (util.sops.userSecret "oc-prod-server" "openshift.yaml" "prod_server")
  ]
  
  # Define templates
  [
    (util.sops.envTemplate "openshift-env" {
      OC_DEV_SERVER = "oc-dev-server";
      OC_STAGE_SERVER = "oc-stage-server";
      OC_PROD_SERVER = "oc-prod-server";
    })
  ]
  
  # Configuration
  {
    home.packages = with pkgs;[
      openshift
      vscode
      discord
      ripgrep
      claude-code
      gh
      git
      (colima.override {
        lima = lima.override { withAdditionalGuestAgents = true; };
      })
      postman
      bruno
      bytecode-viewer
      azure-cli
      element-desktop
    ];

    programs.zsh = {
      enable = true;
      shellAliases = {
        ocdev = "source ${config.sops.templates."openshift-env".path} && oc login --web --server=$OC_DEV_SERVER --insecure-skip-tls-verify";
        ocstage = "source ${config.sops.templates."openshift-env".path} && oc login --web --server=$OC_STAGE_SERVER --insecure-skip-tls-verify";
        ocprod = "source ${config.sops.templates."openshift-env".path} && oc login --web --server=$OC_PROD_SERVER --insecure-skip-tls-verify";
        # Add your custom aliases here
      };
    };
  }
) { inherit config lib; }

