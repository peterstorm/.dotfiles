{config, pkgs, lib, ...}:

{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = "--disable servicelb --disable traefik --write-kubeconfig-mode=644";
  };
}
