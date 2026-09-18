{ config, pkgs, lib, util, ... }:

let
  # Redis 8.10 writes RDB format 15 into Reclaw's multipart AOF. Nixpkgs later
  # regressed its `redis` package to 8.8.1, which cannot read that format and
  # leaves the durable BullMQ state offline. Keep this data store on the first
  # known-compatible release; upgrades remain safe, downgrades do not.
  reclawRedis = pkgs.redis.overrideAttrs (previous: rec {
    version = "8.10.1";
    src = pkgs.fetchFromGitHub {
      owner = "redis";
      repo = "redis";
      tag = version;
      hash = "sha256-fGLuOuiM3VHj70qlSpb2s25RYD8gFARrqwAhW6CIHXE=";
    };
    patches = [
      (pkgs.fetchpatch2 {
        url = "https://github.com/redis/redis/commit/c027c8effe13564bcbc903741305acd929cc23da.patch";
        hash = "sha256-MynmKLQ04JjyHMVbfeSIEnKaj4jvjS1FjQNpfvQz3Pw=";
      })
    ] ++ previous.patches;
  });
in
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

    # Redis instance for reclaw on port 6381. Dedicated port, not 6380: fugue's
    # hand-rolled dev redis convention (redis-server --daemonize yes, started to
    # dodge the busy 6379) grabbed 6380 on 2026-09-15 and reclaw — whose redis
    # runs unauthenticated — was shut down with it and crash-looped for 4h on
    # NOAUTH. Production gets a port no dev workflow contests.
    services.redis.package = reclawRedis;
    services.redis.servers.reclaw = {
      enable = true;
      port = 6381;
      settings = {
        appendonly = "yes";
        appendfsync = "everysec";
      };
    };

    # Linger so user services run without active login
    users.users.peterstorm.linger = true;

    # Headless box: a short power-key press must not take the whole homelab
    # down (2026-09-18 hard reset). Graceful reboots happen via ssh/systemctl.
    services.logind.settings.Login = {
      HandlePowerKey = "ignore";
    };

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
        # Cap the reclaw cgroup: memory.peak includes page cache charged when
        # reclaw-hosted sessions read big files (13.2G peak 2026-09-18 was
        # mostly reclaimable cache). MemoryHigh throttles before pressure;
        # MemoryMax=6G is a hard ceiling well under real anon needs (~0.4G).
        MemoryHigh = "4G";
        MemoryMax = "6G";
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
        REDIS_PORT = "6381";
        WORKSPACE_PATH = "/home/peterstorm/dev/claude-plugins/reclaw/workspace";
        SKILLS_DIR = "/home/peterstorm/dev/claude-plugins/reclaw/workspace/skills";
        PERSONALITY_PATH = "/home/peterstorm/dev/claude-plugins/reclaw/workspace/personality.md";
        AGENT_BACKEND = "pi";
        # Pin pi's provider/model explicitly. Without these, pi falls back to
        # ~/.pi/agent/settings.json, whose default can drift silently — the pin
        # makes the inference target load-bearing instead of incidental.
        # 2026-09-18: routed onto DS4F Vision (desktop vLLM, container
        # ds4-flash-vision-infernal-invocation-cu133-r21-v1, profile
        # ds4-flash-vision-r21-v1) — DeepSeek V4 Flash Vision r21 with DSpark K6
        # (fixed depth 6), vision-capable for Telegram photo attachments, free
        # (self-hosted). Replaces the GLM v13 pin: DS4F Vision is now the
        # desktop's serving profile and matches the model-routing
        # ds4-vision-r21 target (max thinking for subagents).
        # :low thinking suffix: the model's defaultThinkingLevel is max — a
        # plain pin means long Telegram replies; pi's parseModelPattern honours
        # the :low suffix (thinkingLevelMap maps low → low) for responsive replies.
        RECLAW_PI_PROVIDER = "desktop-vllm";
        RECLAW_PI_MODEL = "deepseek-v4-flash-vision:low";
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
        # Native Node addons loaded via dlopen (sharp/onnxruntime via Cortex local embeddings)
        # do not consult NIX_LD_LIBRARY_PATH; they need LD_LIBRARY_PATH present at process start.
        LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib";
      };
    };
  }
) { inherit config lib; }
