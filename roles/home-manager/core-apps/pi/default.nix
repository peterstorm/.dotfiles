{pkgs, config, lib, inputs, ...}:

let
  piDir = ../../../../pi;
  settingsFile = piDir + "/settings.json";

  # Absolute path to pi source in dotfiles repo
  piSrcDir = "${config.home.homeDirectory}/.dotfiles/pi";
  piAgentDir = "${config.home.homeDirectory}/.pi/agent";
  loomDir = "${config.home.homeDirectory}/dev/claude-plugins/loom";

in
{
  home.packages = [ pkgs.pi-coding-agent ];

  # extensions/ and prompts/ are hand-written source, so they stay whole-directory
  # symlinks: adding, editing or removing a file needs no rebuild. models.json and
  # model-routing.json are also live configuration. agents/ cannot work this way —
  # see piAgents below.
  home.activation.piSymlinks = lib.hm.dag.entryAfter ["writeBoundary"] ''
    piAgentDir="${piAgentDir}"
    mkdir -p "$piAgentDir"

    # Create managed resource symlinks (idempotent)
    for resource in extensions prompts models.json model-routing.json; do
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
  # Runs after claudePluginsWorkspace, which provisions the Loom checkout and
  # its node_modules. Configurations without that module (darwin) simply have no
  # Loom checkout, and the render step below reports it and moves on.
  home.activation.piAgents = lib.hm.dag.entryAfter ["writeBoundary" "claudePluginsWorkspace"] ''
    export PATH="${lib.makeBinPath [ pkgs.bun pkgs.coreutils pkgs.diffutils pkgs.gnugrep ]}:$PATH"
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

  # settings.json needs to be mutable (pi writes to it at runtime)
  home.activation.piSettings = lib.hm.dag.entryAfter ["writeBoundary"] ''
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
