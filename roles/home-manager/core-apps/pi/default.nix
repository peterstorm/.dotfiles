{pkgs, config, lib, inputs, ...}:

let
  piDir = ../../../../pi;
  agentFiles = builtins.readDir (piDir + "/agents");
  extensionDirs = builtins.readDir (piDir + "/extensions");
  promptFiles = builtins.readDir (piDir + "/prompts");

  # Symlink all agent markdown files
  agentLinks = lib.mapAttrs' (name: _:
    lib.nameValuePair ".pi/agent/agents/${name}" {
      source = piDir + "/agents/${name}";
    }
  ) (lib.filterAttrs (n: v: v == "regular" && lib.hasSuffix ".md" n) agentFiles);

  # Symlink extension directories (each is a dir with index.ts + supporting files)
  extensionLinks = lib.mapAttrs' (name: _:
    lib.nameValuePair ".pi/agent/extensions/${name}" {
      source = piDir + "/extensions/${name}";
    }
  ) (lib.filterAttrs (_: v: v == "directory") extensionDirs);

  # Symlink prompt templates
  promptLinks = lib.mapAttrs' (name: _:
    lib.nameValuePair ".pi/agent/prompts/${name}" {
      source = piDir + "/prompts/${name}";
    }
  ) (lib.filterAttrs (n: v: v == "regular" && lib.hasSuffix ".md" n) promptFiles);

  settingsFile = piDir + "/settings.json";

in
{
  home.file = agentLinks // extensionLinks // promptLinks;

  # settings.json needs to be mutable (pi writes to it at runtime)
  # Copy it on activation if the managed version is newer or target doesn't exist
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
