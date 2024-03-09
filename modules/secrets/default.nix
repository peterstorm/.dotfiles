{ config, lib, pkgs, ... }:
with lib;

let cfg = config.custom.secrets;

in {
  options.custom.secrets = {
    enable = mkEnableOption "enable sops-nix secrets file";
  };

  config = mkIf cfg.enable {
    sops.defaultSopsFile = ./../../secrets + "/${config.networking.hostName}.yaml";
    sops.age.keyFile = "/var/lib/sops-nix/keys.txt";
    sops.secrets.example_key = {
      mode = "0440";
      owner = "peterstorm";
    };
  };
}
