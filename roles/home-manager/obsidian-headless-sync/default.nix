{ config, pkgs, lib, ... }:

let
  nodejs = pkgs.nodejs_22;
in
{
  home.packages = [ nodejs ];

  systemd.user.services.obsidian-headless-sync = {
    Unit = {
      Description = "Obsidian headless continuous sync";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      Environment = [ "PATH=${lib.makeBinPath [ pkgs.bash pkgs.coreutils nodejs ]}" ];
      ExecStart = pkgs.writeShellScript "obsidian-headless-sync" ''
        exec ${nodejs}/bin/npx --yes --package=obsidian-headless ob sync \
          --path "${config.home.homeDirectory}/dev/notes/remotevault" \
          --continuous
      '';
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStopSec = "10s";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
