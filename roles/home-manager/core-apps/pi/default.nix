{
  pkgs,
  config,
  lib,
  inputs,
  ...
}:

let
  piDir = ../../../../pi;
  settingsFile = piDir + "/settings.json";

  # Absolute path to pi source in dotfiles repo
  piSrcDir = "${config.home.homeDirectory}/.dotfiles/pi";
  piAgentDir = "${config.home.homeDirectory}/.pi/agent";
  loomDir = "${config.home.homeDirectory}/dev/claude-plugins/loom";

  # Creative skills are project resources, not global Pi skills. Home Manager
  # links them into ~/dev/creative/.pi/skills, so Pi discovers them only when
  # that exact directory is Pi's cwd. Unlicensed cinema documents stay out of
  # this public repository and are fetched from the checksum-pinned archive.
  archivedCreativeProjectSkillNames = [
    "banana-pro-director-30"
    "character-builder"
    "cinema-director"
    "story-bible-builder"
  ];
  authoredCreativeProjectSkillNames = [
    "action-physics-production"
    "blender-previz"
    "blocking-continuity"
    "ensemble-action-production"
    "h3-prompt-distillation"
    "human-motion-realism-production"
    "identity-realism-production"
    "location-world-production"
    "performance-direction"
    "prop-continuity"
    "synthetic-voice-production"
    "wardrobe-asset-production"
  ];
  creativeProjectSkillProvenance = builtins.fromJSON (
    builtins.readFile (piDir + "/project-skills/creative/provenance.json")
  );
  creativeProjectSkillArchive = pkgs.fetchurl {
    inherit (creativeProjectSkillProvenance) url;
    hash = creativeProjectSkillProvenance.archiveSha256;
  };
  musicCaptionRewriterSource = pkgs.fetchFromGitHub {
    owner = "MiniMax-AI";
    repo = "MiniMax-Music3";
    rev = creativeProjectSkillProvenance.officialMusicCaptionRewriter.revision;
    hash = creativeProjectSkillProvenance.officialMusicCaptionRewriter.sourceSha256;
  };
  h3PromptWritingSource = pkgs.fetchFromGitHub {
    owner = "MiniMax-AI";
    repo = "MiniMax-H3";
    rev = creativeProjectSkillProvenance.officialH3PromptWriting.revision;
    hash = creativeProjectSkillProvenance.officialH3PromptWriting.sourceSha256;
  };
  creativeProjectSkillManifest = pkgs.writeText "pi-creative-project-skills.sha256" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (path: hash: "${hash}  ${path}") creativeProjectSkillProvenance.files
    )
    + "\n"
  );
  creativeProjectSkills =
    pkgs.runCommand "pi-creative-project-skills"
      {
        nativeBuildInputs = [ pkgs.unzip ];
      }
      ''
        mkdir -p "$out/skills" source
        cd source
        for name in ${lib.escapeShellArgs archivedCreativeProjectSkillNames}; do
          unzip -q ${creativeProjectSkillArchive} "$name.zip"
          unzip -q "$name.zip" -d "$out/skills"
          test -f "$out/skills/$name/SKILL.md"
        done
        cd "$out"
        ${pkgs.coreutils}/bin/sha256sum -c ${creativeProjectSkillManifest}
      '';
  creativeProjectSkillLinks = builtins.listToAttrs (
    map (name: {
      name = "dev/creative/.pi/skills/${name}";
      value.source = creativeProjectSkills + "/skills/${name}";
    }) archivedCreativeProjectSkillNames
    ++ [
      {
        name = "dev/creative/.pi/skills/music-caption-rewriter";
        value.source = musicCaptionRewriterSource + "/skills/music-caption-rewriter";
      }
      {
        name = "dev/creative/.pi/skills/h3-prompt-writing";
        value.source = h3PromptWritingSource + "/skills/h3-prompt-writing";
      }
    ]
    ++ map (name: {
      name = "dev/creative/.pi/skills/${name}";
      value.source = piDir + "/project-skills/creative/${name}";
    }) authoredCreativeProjectSkillNames
  );

  # models.json holds exactly one machine-dependent value: the desktop-vllm
  # baseUrl. Hosts that can route 192.168.0.0/24 — LAN clients, and WARP-enrolled
  # devices via the tunnel's private network route — reach the workstation at its
  # own address. The work Mac can do neither: a full-tunnel corporate VPN claims
  # that prefix outright, and the account has no admin rights to install anything
  # that would route around it. There the endpoint arrives on loopback, via the
  # `vllm-forward` Access-authenticated tunnel from the darwin role.
  #
  # Authentication is also host-specific. Darwin consumes the SOPS-managed
  # credential shipped by dotfiles directly; endpoint-specific files can be stale
  # after a server-side rotation and must never shadow that source of truth. Other
  # hosts retain the launcher-compatible resolution order from models.json.
  isLoopbackVllm = pkgs.stdenv.hostPlatform.isDarwin;
  vllmBaseUrl = "http://localhost:8000/v1";
  vllmApiKeyCommand = "!cat \"$HOME/.config/sops-nix/secrets/vllm-api-key\"";

in
{
  home.packages = [ pkgs.pi-coding-agent ];

  home.file = creativeProjectSkillLinks // {
    "dev/creative/.pi/settings.json".source = piDir + "/project-config/creative/settings.json";
    "dev/creative/.mcp.json".source = piDir + "/project-config/creative/mcp.json";
  };

  # extensions/ and prompts/ are hand-written source, so they stay whole-directory
  # symlinks: adding, editing or removing a file needs no rebuild. models.json and
  # model-routing.json are also live configuration. agents/ cannot work this way —
  # see piAgents below.
  #
  # On a loopback-vLLM host models.json is generated rather than symlinked, so
  # editing it there does need a rebuild. That is the price of the one rewritten
  # field; every other host keeps the live symlink.
  home.activation.piSymlinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    piAgentDir="${piAgentDir}"
    mkdir -p "$piAgentDir"

    # Create managed resource symlinks (idempotent)
    for resource in extensions prompts ${
      lib.optionalString (!isLoopbackVllm) "models.json"
    } model-routing.json; do
      target="${piSrcDir}/$resource"
      link="$piAgentDir/$resource"

      if [ -L "$link" ]; then
        # Already a symlink — update if target changed
        current=$(readlink "$link")
        if [ "$current" != "$target" ]; then
          rm "$link"
          ln -s "$target" "$link"
          echo "pi: updated $resource symlink"
        fi
      elif [ -e "$link" ]; then
        # Something else exists (file/dir) — back up and replace
        mv "$link" "$link.bak.$(date +%s)"
        ln -s "$target" "$link"
        echo "pi: replaced $resource with symlink (old backed up)"
      else
        ln -s "$target" "$link"
        echo "pi: created $resource symlink"
      fi
    done
    ${lib.optionalString isLoopbackVllm ''

      # models.json with desktop-vllm rewritten to loopback (see comment above).
      # Replaces any inherited symlink from before this host became loopback.
      link="$piAgentDir/models.json"
      [ -L "$link" ] && rm "$link"
      ${pkgs.jq}/bin/jq \
        --arg url "${vllmBaseUrl}" \
        --arg apiKey '${vllmApiKeyCommand}' \
        '.providers."desktop-vllm" |= (.baseUrl = $url | .apiKey = $apiKey)' \
        "${piSrcDir}/models.json" > "$link.tmp" && mv "$link.tmp" "$link"
      echo "pi: models.json generated with loopback endpoint and SOPS-managed authentication"
    ''}
  '';

  # agents/ is a REAL directory holding two kinds of file:
  #
  #   symlinks  -> the generic agents this repo owns (planner, scout, ...)
  #   real files -> Loom's roster, rendered per machine
  #
  # It cannot be a symlink into the dotfiles repo. Loom's
  # scripts/sync-pi-agents.sh writes into $PI_CODING_AGENT_DIR/agents, so that
  # layout made Loom's build output land inside version control. Those renders
  # are machine-bound (absolute package root, inlined skill bodies) and go stale
  # on every Loom commit, and Loom's pre-tool-use guard blocks any agent whose
  # file is not byte-for-byte the current render — so they must be generated
  # here, per machine, and never committed.
  #
  # Runs after claudePluginsWorkspace, which provisions the Loom checkout and its
  # node_modules. Every configuration that imports this role also imports
  # core-apps/claude, so that ordering holds — but the edge is only advisory:
  # home-manager's topological sort ignores a dependency on an absent node rather
  # than failing, so a configuration that dropped the claude role would still
  # activate, just with no Loom checkout. The render step below reports that and
  # moves on.
  home.activation.piAgents = lib.hm.dag.entryAfter [ "writeBoundary" "claudePluginsWorkspace" ] ''
    export PATH="${
      lib.makeBinPath [
        pkgs.bun
        pkgs.coreutils
        pkgs.diffutils
        pkgs.gnugrep
      ]
    }:$PATH"
    agentsDir="${piAgentDir}/agents"

    # Migrate the old whole-directory symlink into the dotfiles repo.
    if [ -L "$agentsDir" ]; then
      rm "$agentsDir"
      echo "pi: agents/ is no longer a symlink into the dotfiles repo (Loom renders into it)"
    fi
    mkdir -p "$agentsDir"

    # 1. The agents this repo owns, linked per file so edits stay live.
    for src in "${piSrcDir}"/agents/*.md; do
      [ -e "$src" ] || continue
      link="$agentsDir/$(basename "$src")"
      if [ ! -L "$link" ] || [ "$(readlink "$link")" != "$src" ]; then
        rm -f "$link"
        ln -s "$src" "$link"
        echo "pi: linked $(basename "$src")"
      fi
    done

    # 2. Drop renders for agents Loom no longer ships. The sync script only
    #    writes; without this a deleted Loom agent lingers forever.
    if [ -d "${loomDir}/agents" ]; then
      for f in "$agentsDir"/*.md; do
        [ -e "$f" ] || continue
        [ -L "$f" ] && continue
        grep -q '<!-- LOOM_PI_AGENT_ID:' "$f" || continue
        if [ ! -f "${loomDir}/agents/$(basename "$f")" ]; then
          rm -f "$f"
          echo "pi: pruned stale Loom agent $(basename "$f")"
        fi
      done
    fi

    # 3. Render Loom's roster for this machine.
    if [ -x "${loomDir}/scripts/sync-pi-agents.sh" ]; then
      "${loomDir}/scripts/sync-pi-agents.sh" \
        || echo "pi: WARNING — Loom agent render failed; Loom subagents stay blocked until 'loom-sync' succeeds" >&2
    else
      echo "pi: no Loom checkout at ${loomDir} — skipping agent render" >&2
    fi
  '';

  # skills/ is a REAL directory (like agents/): pi discovers skills recursively
  # under ~/.pi/agent/skills/, and other tools (npx skills add, Anthropic's
  # installer, loom) may write additional skills into it. Linking the whole
  # directory would drag those external installs into version control, so each
  # skill this repo owns is linked per-directory instead. Adding a skill = drop
  # it into pi/skills/ and it appears on the next activation, no rebuild.
  home.activation.piSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }:$PATH"
    skillsDir="${piAgentDir}/skills"
    srcSkillsDir="${piSrcDir}/skills"

    mkdir -p "$skillsDir"

    # 1. Link each skill this repo owns (idempotent, updates on target change).
    for src in "$srcSkillsDir"/*/; do
      [ -d "$src" ] || continue
      [ -f "$src/SKILL.md" ] || continue
      name="$(basename "$src")"
      link="$skillsDir/$name"
      if [ -L "$link" ]; then
        if [ "$(readlink "$link")" != "$src" ]; then
          rm "$link"
          ln -s "$src" "$link"
          echo "pi: updated skill $name"
        fi
      elif [ -e "$link" ]; then
        mv "$link" "$link.bak.$(date +%s)"
        ln -s "$src" "$link"
        echo "pi: replaced skill $name with symlink (old backed up)"
      else
        ln -s "$src" "$link"
        echo "pi: linked skill $name"
      fi
    done

    # 2. Prune symlinks to skills this repo no longer ships.
    for link in "$skillsDir"/*; do
      [ -L "$link" ] || continue
      target="$(readlink "$link")"
      case "$target" in
        "$srcSkillsDir"/*)
          [ -e "$target" ] || { rm "$link"; echo "pi: pruned stale skill $(basename "$link")"; }
          ;;
      esac
    done
  '';

  # settings.json needs to be mutable (pi writes to it at runtime)
  home.activation.piSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    piSettingsDir="${piAgentDir}"
    piSettingsTarget="$piSettingsDir/settings.json"
    piSettingsSource="${settingsFile}"

    mkdir -p "$piSettingsDir"

    if [ ! -f "$piSettingsTarget" ]; then
      cp "$piSettingsSource" "$piSettingsTarget"
      chmod 644 "$piSettingsTarget"
      echo "pi: installed settings.json"
    else
      # Only overwrite if source is different (ignoring lastChangelogVersion)
      if ! diff -q <(${pkgs.jq}/bin/jq 'del(.lastChangelogVersion)' "$piSettingsSource") \
                   <(${pkgs.jq}/bin/jq 'del(.lastChangelogVersion)' "$piSettingsTarget") >/dev/null 2>&1; then
        # Preserve lastChangelogVersion from existing file
        existingVersion=$(${pkgs.jq}/bin/jq -r '.lastChangelogVersion // empty' "$piSettingsTarget")
        cp "$piSettingsSource" "$piSettingsTarget"
        if [ -n "$existingVersion" ]; then
          ${pkgs.jq}/bin/jq --arg v "$existingVersion" '.lastChangelogVersion = $v' "$piSettingsTarget" > "$piSettingsTarget.tmp"
          mv "$piSettingsTarget.tmp" "$piSettingsTarget"
        fi
        chmod 644 "$piSettingsTarget"
        echo "pi: updated settings.json (preserved lastChangelogVersion)"
      fi
    fi
  '';
}
