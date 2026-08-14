{ pkgs, config, lib, ... }:

let
  homeDir = config.home.homeDirectory;
  pluginsDir = "${homeDir}/dev/claude-plugins";

  # Each Claude Code plugin is its own git repo AND its own one-plugin
  # marketplace (registered below via extraKnownMarketplaces). Other tools
  # (pi, opencode, reclaw) read these repos directly off disk, so we also clone
  # them into ~/dev/claude-plugins on every machine.
  workspaceRepos = [ "loom" "cortex" "feynman" "obsidian" "reclaw" ];

  # Canonical ~/.claude/settings.json content. Deep-merged into the live file so
  # Claude Code's runtime-written keys (onboarding flags, project-scoped
  # plugins, CLI-added marketplaces) survive while these managed keys are
  # enforced from the dotfiles.
  managedSettings = {
    model = "opus[1m]";
    effortLevel = "high";
    autoCompactEnabled = true;
    env = { CLAUDE_CODE_DISABLE_BACKGROUND_TASKS = "1"; };
    statusLine = {
      type = "command";
      command = "~/.dotfiles/claude/global/statusline-command.sh";
    };
    enabledPlugins = {
      "loom@loom" = true;
      "cortex@cortex" = true;
      "feynman@feynman" = true;
    };
    extraKnownMarketplaces = {
      impeccable.source      = { source = "github"; repo = "pbakaus/impeccable"; };
      frontend-slides.source = { source = "github"; repo = "zarazhangrui/frontend-slides"; };
      loom.source            = { source = "github"; repo = "peterstorm/loom"; };
      cortex.source          = { source = "github"; repo = "peterstorm/cortex"; };
      feynman.source         = { source = "github"; repo = "peterstorm/feynman"; };
    };
  };

  managedFile = pkgs.writeText "claude-settings-managed.json"
    (builtins.toJSON managedSettings);
in
{
  # 1. Provision the plugin/workspace repos that pi, opencode and reclaw read
  #    directly off disk. Idempotent — only clones a repo that isn't present.
  home.activation.claudePluginsWorkspace =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.git pkgs.coreutils pkgs.bun ]}:$PATH"
      d="${pluginsDir}"
      mkdir -p "$d"
      ${lib.concatMapStringsSep "\n      " (r: ''
        if [ ! -d "$d/${r}/.git" ]; then
          echo "claude: cloning ${r} -> $d/${r}"
          git clone "https://github.com/peterstorm/${r}.git" "$d/${r}" \
            || echo "claude: clone of ${r} failed (continuing)"
        fi
        # pi/opencode run these repos straight off disk. pi only runs an install
        # for packages IT installs; we clone manually, so provision JS deps here.
        # Reinstall when the manifest or lockfile is newer than node_modules: a
        # pull that adds a dependency must not leave a stale tree, or pi fails at
        # extension load with "Cannot find module". Skip when up to date to keep
        # activation fast.
        if [ -f "$d/${r}/package.json" ] && { [ ! -d "$d/${r}/node_modules" ] \
             || [ "$d/${r}/package.json" -nt "$d/${r}/node_modules" ] \
             || [ "$d/${r}/bun.lock" -nt "$d/${r}/node_modules" ]; }; then
          echo "claude: bun install in ${r} (deps out of date)"
          # touch node_modules afterwards so bun.lock (possibly rewritten after
          # the node tree) can never look newer on the next activation.
          ( cd "$d/${r}" && bun install --no-progress && touch node_modules ) \
            || echo "claude: bun install for ${r} failed (continuing)"
        fi
      '') workspaceRepos}
    '';

  # 2. Enforce the plugin wiring in ~/.claude/settings.json without clobbering
  #    runtime-written keys. Deep-merge: existing * managed (managed wins on
  #    overlapping keys, unions nested objects, leaves the rest untouched).
  home.activation.claudeSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.jq pkgs.coreutils ]}:$PATH"
      settings="$HOME/.claude/settings.json"
      mkdir -p "$HOME/.claude"
      if [ -f "$settings" ]; then
        tmp="$(mktemp)"
        if jq -s '.[0] * .[1]' "$settings" ${managedFile} > "$tmp"; then
          mv "$tmp" "$settings"
          echo "claude: merged managed settings into settings.json"
        else
          rm -f "$tmp"
          echo "claude: WARNING jq merge failed, left settings.json untouched"
        fi
      else
        cp ${managedFile} "$settings"
        echo "claude: created settings.json from managed defaults"
      fi
      chmod 644 "$settings"
    '';
}
