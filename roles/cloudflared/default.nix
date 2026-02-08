{config, pkgs, lib, util, ...}:

(util.sops.mkSecretsAndTemplatesConfig
  [
    (util.sops.hostSecret "cloudflared-tunnel-creds" "cloudflared-tunnel.json" "AccountTag" { format = "json"; owner = null; group = null; })
    (util.sops.hostSecret "cloudflared-tunnel-secret" "cloudflared-tunnel.json" "TunnelSecret" { format = "json"; owner = null; group = null; })
    (util.sops.hostSecret "cloudflared-tunnel-id" "cloudflared-tunnel.json" "TunnelID" { format = "json"; owner = null; group = null; })
  ]
  [
    {
      name = "cloudflared-tunnel-credentials";
      content = builtins.toJSON {
        AccountTag = config.sops.placeholder."cloudflared-tunnel-creds";
        TunnelSecret = config.sops.placeholder."cloudflared-tunnel-secret";
        TunnelID = config.sops.placeholder."cloudflared-tunnel-id";
      };
      owner = "cloudflared";
      group = "cloudflared";
      mode = "0400";
    }
  ]
  {
    disabledModules = [ "services/networking/cloudflared.nix" ];

    imports = [
      ./myCloudflared.nix
    ];

    services.cloudflared = {
      enable = true;
      tunnels = {
        "206b7a4a-a658-437d-a98b-c14c6e4cc286" = {
          credentialsFile = config.sops.templates."cloudflared-tunnel-credentials".path;
          warp-routing.enabled = true;
          default = "http_status:404";
        };
      };
    };
  }
) { inherit config lib; }
