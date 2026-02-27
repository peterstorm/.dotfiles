{ config, pkgs, lib, util, ... }:

(util.sops.mkSecretsAndTemplatesConfig
  # 1. Secrets — decrypted to /run/secrets/
  [
    (util.sops.hostSecret "reclaw-telegram-token" "reclaw.yaml" "telegram_token" { owner = "peterstorm"; group = "users"; })
    (util.sops.hostSecret "reclaw-gemini-api-key" "reclaw.yaml" "gemini_api_key" { owner = "peterstorm"; group = "users"; })
  ]

  # 2. Templates — systemd env file (no 'export' prefix)
  [
    {
      name = "reclaw-env";
      content = ''
        TELEGRAM_TOKEN=${config.sops.placeholder."reclaw-telegram-token"}
        GEMINI_API_KEY=${config.sops.placeholder."reclaw-gemini-api-key"}
      '';
      owner = "peterstorm";
      group = "users";
    }
  ]

  # 3. NixOS configuration
  {
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

      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "/home/peterstorm/dev/claude-plugins/reclaw";
        EnvironmentFile = config.sops.templates."reclaw-env".path;
        ExecStart = "${pkgs.bun}/bin/bun run src/main.ts";
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
        CLAUDE_BINARY_PATH = "/home/peterstorm/.nix-profile/bin/claude";
        OBSIDIAN_VAULT_PATH = "/home/peterstorm/dev/notes";
        CHAT_TIMEOUT_MS = "120000";
        SCHEDULED_TIMEOUT_MS = "300000";
        AUTHORIZED_USER_IDS = "5061662914";
        TZ = "Europe/Copenhagen";
      };
    };
  }
) { inherit config lib; }
