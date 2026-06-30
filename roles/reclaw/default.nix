{ config, pkgs, lib, util, ... }:

(util.sops.mkSecretsAndTemplatesConfig
  # 1. Secrets — decrypted to /run/secrets/
  [
    (util.sops.hostSecret "reclaw-telegram-token" "reclaw.yaml" "telegram_token" { owner = "peterstorm"; group = "users"; })
    (util.sops.hostSecret "reclaw-gemini-api-key" "reclaw.yaml" "gemini_api_key" { owner = "peterstorm"; group = "users"; })
    (util.sops.hostSecret "reclaw-google-email" "reclaw.yaml" "google_email" { owner = "peterstorm"; group = "users"; })
    (util.sops.hostSecret "reclaw-google-password" "reclaw.yaml" "google_password" { owner = "peterstorm"; group = "users"; })
    (util.sops.hostSecret "reclaw-garmin-email" "reclaw.yaml" "garmin_email" { owner = "peterstorm"; group = "users"; })
    (util.sops.hostSecret "reclaw-garmin-password" "reclaw.yaml" "garmin_password" { owner = "peterstorm"; group = "users"; })
    # (util.sops.hostSecret "reclaw-notebooklm-auth-token" "reclaw.yaml" "notebooklm_auth_token" { owner = "peterstorm"; group = "users"; })
    # (util.sops.hostSecret "reclaw-notebooklm-cookies" "reclaw.yaml" "notebooklm_cookies" { owner = "peterstorm"; group = "users"; })
  ]

  # 2. Templates — systemd env file (no 'export' prefix)
  [
    {
      name = "reclaw-env";
      content = ''
        TELEGRAM_TOKEN=${config.sops.placeholder."reclaw-telegram-token"}
        GEMINI_API_KEY=${config.sops.placeholder."reclaw-gemini-api-key"}
        GOOGLE_EMAIL=${config.sops.placeholder."reclaw-google-email"}
        GOOGLE_PASSWORD=${config.sops.placeholder."reclaw-google-password"}
        GARMIN_EMAIL=${config.sops.placeholder."reclaw-garmin-email"}
        GARMIN_PASSWORD=${config.sops.placeholder."reclaw-garmin-password"}
      '';
      owner = "peterstorm";
      group = "users";
    }
  ]

  # 3. NixOS configuration
  {
    # nix-ld: run unpatched, dynamically-linked ELF binaries on NixOS.
    # Reclaw is a bun/JS project; several npm devDependencies ship prebuilt
    # generic-linux binaries (e.g. @biomejs/cli-linux-x64/biome, esbuild) that
    # NixOS can't exec out of the box — `bun run lint` (biome 1.9.4) otherwise
    # dies with "Could not start dynamically linked executable". Enabling nix-ld
    # provides the stub loader + a base library set so the pinned npm binary
    # runs as-is, with zero version drift from package.json / biome.json.
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc.lib  # libstdc++ / libgcc_s — Rust & native node addons
      zlib
      openssl
    ];

    # Redis instance for reclaw on port 6380
    services.redis.servers.reclaw = {
      enable = true;
      port = 6380;
      settings = {
        appendonly = "yes";
        appendfsync = "everysec";
      };
    };

    # Linger so user services run without active login
    users.users.peterstorm.linger = true;

    # Reclaw user service — restartable without sudo/polkit
    systemd.user.services.reclaw = {
      description = "Reclaw Telegram AI Agent";
      after = [ "network.target" ];
      wantedBy = [ "default.target" ];

      # Stop the crash-loop after 5 restarts within 5 minutes — without
      # these, an unhandled rejection at boot would loop forever every 10s.
      # These belong on the [Unit] section, not [Service].
      startLimitBurst = 5;
      startLimitIntervalSec = 300;

      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "/home/peterstorm/dev/claude-plugins/reclaw";
        EnvironmentFile = config.sops.templates."reclaw-env".path;
        ExecStart = "${pkgs.bun}/bin/bun run src/main.ts";
        ExecStopPost = "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/mkdir -p /home/peterstorm/.local/share/reclaw && echo \"[$(${ pkgs.coreutils}/bin/date -Iseconds)] stopped: result=$SERVICE_RESULT exit=$EXIT_CODE/$EXIT_STATUS sessions=$(${pkgs.systemd}/bin/loginctl list-sessions --no-legend 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)\" >> /home/peterstorm/.local/share/reclaw/stop-audit.log'";
        Restart = "on-failure";
        RestartSec = "10s";
      };

      environment = {
        HOME = "/home/peterstorm";
        PATH = lib.mkForce "/home/peterstorm/.nix-profile/bin:/nix/profile/bin:/home/peterstorm/.local/state/nix/profile/bin:/etc/profiles/per-user/peterstorm/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/run/wrappers/bin";
        REDIS_HOST = "127.0.0.1";
        REDIS_PORT = "6380";
        WORKSPACE_PATH = "/home/peterstorm/dev/claude-plugins/reclaw/workspace";
        SKILLS_DIR = "/home/peterstorm/dev/claude-plugins/reclaw/workspace/skills";
        PERSONALITY_PATH = "/home/peterstorm/dev/claude-plugins/reclaw/workspace/personality.md";
        AGENT_BACKEND = "pi";
        AUTHORIZED_USER_IDS = "5061662914";
        OBSIDIAN_VAULT_PATH = "/home/peterstorm/dev/notes/remotevault";
        TZ = "Europe/Copenhagen";
        # Location for skills that fetch weather/sun (open-meteo, etc).
        # Defaults match Copenhagen — change here when travelling long-term.
        LATITUDE = "55.665";
        LONGITUDE = "12.57";
        TZ_NAME = "Europe/Copenhagen";
        LOCATION_NAME = "Copenhagen";
        PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
      };
    };
  }
) { inherit config lib; }
