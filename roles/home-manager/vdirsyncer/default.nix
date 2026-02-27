{ config, pkgs, lib, util, ... }:

(util.sops.mkSecretsAndTemplatesConfig
  # Secrets: iCloud app-specific password
  [
    (util.sops.userSecret "icloud-password" "icloud.yaml" "password")
    (util.sops.userSecret "icloud-username" "icloud.yaml" "username")
  ]

  # Templates: vdirsyncer config with secret placeholders
  [
    {
      name = "vdirsyncer-config";
      content = ''
        [general]
        status_path = "${config.home.homeDirectory}/.local/share/vdirsyncer/status/"

        [pair icloud_calendar]
        a = "icloud_local"
        b = "icloud_remote"
        collections = ["from a", "from b"]
        conflict_resolution = "b wins"

        [storage icloud_local]
        type = "filesystem"
        path = "${config.home.homeDirectory}/.local/share/calendars/icloud/"
        fileext = ".ics"

        [storage icloud_remote]
        type = "caldav"
        url = "https://caldav.icloud.com/"
        username = "${config.sops.placeholder."icloud-username"}"
        password = "${config.sops.placeholder."icloud-password"}"
      '';
    }
  ]

  # Configuration: package, directories, service, timer
  {
    home.packages = [ pkgs.vdirsyncer ];

    systemd.user.services.vdirsyncer-sync = {
      Unit = {
        Description = "Sync iCloud calendars via vdirsyncer";
      };

      Service = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "vdirsyncer-sync" ''
          set -e
          ${pkgs.coreutils}/bin/mkdir -p "${config.home.homeDirectory}/.local/share/calendars/icloud"
          ${pkgs.coreutils}/bin/mkdir -p "${config.home.homeDirectory}/.local/share/vdirsyncer/status"

          export VDIRSYNCER_CONFIG="${config.sops.templates."vdirsyncer-config".path}"

          # Auto-confirm new calendar discovery
          ${pkgs.coreutils}/bin/yes | ${pkgs.vdirsyncer}/bin/vdirsyncer discover
          ${pkgs.vdirsyncer}/bin/vdirsyncer sync
        '';
      };
    };

    systemd.user.timers.vdirsyncer-sync = {
      Unit = {
        Description = "Timer for iCloud calendar sync";
      };

      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "15min";
        Persistent = true;
      };

      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
  }
) { inherit config lib; }
