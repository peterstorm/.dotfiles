{config, pkgs, lib, ...}:

{
  disabledModules = [ "services/networking/cloudflared.nix" ];

  imports = [
    ./myCloudflared.nix
  ];

  services.cloudflared = {
    enable = true;
    tunnels = {
      "206b7a4a-a658-437d-a98b-c14c6e4cc286" = {
        credentialsFile = "/var/lib/cloudflared/206b7a4a-a658-437d-a98b-c14c6e4cc286.json";
        warp-routing.enabled = true;
        default = "http_status:404";
      };
    };
  };
}
