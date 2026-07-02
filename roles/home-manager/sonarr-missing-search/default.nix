{ config, pkgs, ... }:

{
  systemd.user.services.sonarr-missing-search = {
    Unit = {
      Description = "Search Sonarr for missing episodes";
    };

    Service = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "sonarr-missing-search" ''
        set -e
        SONARR_URL="http://10.43.28.201:8989"
        API_KEY=$(${pkgs.gnugrep}/bin/grep -oP '(?<=<ApiKey>)[^<]+' /var/data/configs/sonarr/config.xml)

        ${pkgs.curl}/bin/curl -sf -X POST "$SONARR_URL/api/v3/command" \
          -H "X-Api-Key: $API_KEY" \
          -H "Content-Type: application/json" \
          -d '{"name": "MissingEpisodeSearch"}'
      '';
    };
  };

  systemd.user.timers.sonarr-missing-search = {
    Unit = {
      Description = "Daily search for missing episodes in Sonarr";
    };

    Timer = {
      OnCalendar = "daily";
      OnBootSec = "5min";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };

    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
