{ config, pkgs, lib, util, ... }:

(util.sops.mkSecretsAndTemplatesConfig
  # 1. Secrets — decrypted to /run/secrets/
  [
    (util.sops.hostSecret "reclaw-telegram-token" "reclaw.yaml" "telegram_token" {})
    (util.sops.hostSecret "reclaw-gemini-api-key" "reclaw.yaml" "gemini_api_key" {})
  ]

  # 2. Templates — env file with actual secret values
  [
    (util.sops.envTemplate "reclaw-env" {
      TELEGRAM_TOKEN = "reclaw-telegram-token";
      GEMINI_API_KEY = "reclaw-gemini-api-key";
    })
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

    # Reclaw systemd service
    systemd.services.reclaw = {
      description = "Reclaw Telegram AI Agent";
      after = [ "network.target" "redis-reclaw.service" ];
      requires = [ "redis-reclaw.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "peterstorm";
        Group = "users";
        WorkingDirectory = "/home/peterstorm/dev/claude-plugins/reclaw";
        EnvironmentFile = config.sops.templates."reclaw-env".path;
        ExecStart = "${pkgs.bun}/bin/bun run src/main.ts";
        Restart = "on-failure";
        RestartSec = "10s";
      };

      environment = {
        REDIS_HOST = "127.0.0.1";
        REDIS_PORT = "6380";
        WORKSPACE_PATH = "/home/peterstorm/dev/claude-plugins/reclaw/workspace";
        SKILLS_DIR = "/home/peterstorm/dev/claude-plugins/reclaw/workspace/skills";
        PERSONALITY_PATH = "/home/peterstorm/dev/claude-plugins/reclaw/workspace/personality.md";
        CLAUDE_BINARY_PATH = "claude";
        OBSIDIAN_VAULT_PATH = "/home/peterstorm/dev/notes";
        CHAT_TIMEOUT_MS = "120000";
        SCHEDULED_TIMEOUT_MS = "300000";
        AUTHORIZED_USER_IDS = "5061662914";
        TZ = "Europe/Copenhagen";
      };
    };
  }
) { inherit config lib; }
