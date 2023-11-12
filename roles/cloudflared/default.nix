{config, pkgs, lib, ...}:

{
  services.cloudflared = {
    enable = true;
    tunnels = {
      "206b7a4a-a658-437d-a98b-c14c6e4cc286" = {
        credentialsFile = "/home/peterstorm/.cloudflared/206b7a4a-a658-437d-a98b-c14c6e4cc286.json";
        warp-routing.enabled = true;
        default = "http_status:404";
      };
    };
  };
}
