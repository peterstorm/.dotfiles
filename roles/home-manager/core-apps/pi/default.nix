{pkgs, config, lib, inputs, ...}:

let
  piDir = ../../../../pi;
  settingsFile = piDir + "/settings.json";

  # Absolute path to pi source in dotfiles repo
  piSrcDir = "${config.home.homeDirectory}/.dotfiles/pi";

in
{
  home.packages = [ pkgs.pi-coding-agent ];

  # Symlink entire directories to dotfiles repo (not per-file).
  # This means adding/editing/removing files needs NO rebuild.
  home.activation.piSymlinks = lib.hm.dag.entryAfter ["writeBoundary"] ''
    piAgentDir="$HOME/.pi/agent"
    mkdir -p "$piAgentDir"

    # Create directory-level symlinks (idempotent)
    for dir in agents extensions prompts; do
      target="${piSrcDir}/$dir"
      link="$piAgentDir/$dir"

      if [ -L "$link" ]; then
        # Already a symlink — update if target changed
        current=$(readlink "$link")
        if [ "$current" != "$target" ]; then
          rm "$link"
          ln -s "$target" "$link"
          echo "pi: updated $dir symlink"
        fi
      elif [ -e "$link" ]; then
        # Something else exists (file/dir) — back up and replace
        mv "$link" "$link.bak.$(date +%s)"
        ln -s "$target" "$link"
        echo "pi: replaced $dir with symlink (old backed up)"
      else
        ln -s "$target" "$link"
        echo "pi: created $dir symlink"
      fi
    done
  '';

  # settings.json needs to be mutable (pi writes to it at runtime)
  home.activation.piSettings = lib.hm.dag.entryAfter ["writeBoundary"] ''
    piSettingsDir="$HOME/.pi/agent"
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
