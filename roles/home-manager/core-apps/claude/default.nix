{ pkgs, config, lib, ... }:

let
  cfg = config.dotfiles.claude;

  homeDir = config.home.homeDirectory;
  pluginsDir = "${homeDir}/dev/claude-plugins";

  # Every repo cloned into ~/dev/claude-plugins, plugin or not. Derived rather
  # than hand-kept: a repo can be a plugin or a bare workspace checkout, never
  # both (asserted below), and every enabled plugin is by construction a repo we
  # clone. That kills the old failure mode where enabledPlugins named a plugin
  # workspaceRepos never fetched.
  workspaceRepos = cfg.plugins ++ cfg.extraWorkspaceRepos;

  # `<name>@local` for each plugin — the marketplace generated at activation from
  # these same clones.
  localPlugins = lib.listToAttrs
    (map (p: lib.nameValuePair "${p}@local" true) cfg.plugins);

  # The `local` marketplace points Claude Code at the workspace clones instead
  # of at github tarballs, so a plugin resolves LIVE from its checkout: edit the
  # repo, the plugin changes, no reinstall. It is generated at activation (see
  # claudeLocalMarketplace) rather than committed, because the directory holds
  # absolute symlinks into $HOME and is gitignored.
  localMarketplaceDir = "${homeDir}/.dotfiles/.claude/local-marketplace";

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
    # The `local` marketplace symlinks straight into the workspace repos cloned
    # below, so these resolve LIVE from ~/dev/claude-plugins/<name> — edit the
    # checkout and the plugin changes, no reinstall step.
    #
    # The marketplace these point at is gitignored, but claudeLocalMarketplace
    # regenerates it on every activation, so a fresh machine needs no manual
    # step.
    #
    # The pre-local github/directory installs are pinned to `false`, not merely
    # left out. Two enabled copies of one plugin register their hooks twice, and
    # the github tarball ships no engine/node_modules so cortex's embedder cannot
    # load at all — but claudeSettings deep-merges, and a merge can only override
    # a key, never delete one. Absent here, a stale `"loom@loom": true` written
    # before this role existed would survive every activation forever. `false`
    # is the only way to actually retract it. (A deliberate `claude plugin
    # install loom@loom` still works; the next activation just wins it back.)
    enabledPlugins = localPlugins // {
      "loom@loom" = false;
      "cortex@cortex" = false;
      "feynman@plugins" = false;
    };
    extraKnownMarketplaces = {
      # Declares the local marketplace so a fresh machine registers it from the
      # dotfiles rather than needing `claude plugin marketplace add` by hand.
      local.source           = { source = "directory"; path = localMarketplaceDir; };
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
  # Per-machine surface. The defaults are the full set; a machine that lacks the
  # backing state for one of them (no Obsidian vault, no reclaw work) narrows the
  # list from its flake entry rather than forking this role. See lib/user.nix →
  # mkHMUser's extraModules.
  options.dotfiles.claude = {
    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "loom" "cortex" "feynman" "obsidian" ];
      example = [ "loom" "cortex" ];
      description = ''
        peterstorm/<name> repos that are Claude Code plugins. Each is cloned into
        ~/dev/claude-plugins, published through the generated `local` marketplace,
        and enabled as <name>@local. One list drives all three, so a plugin can
        never be enabled without being fetched.
      '';
    };

    extraWorkspaceRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "reclaw" ];
      example = [ ];
      description = ''
        peterstorm/<name> repos cloned into ~/dev/claude-plugins that are NOT
        plugins — other tools read them straight off disk. Never published to the
        marketplace, never enabled.
      '';
    };
  };

  config = {

  # A repo is a plugin or a plain checkout, never both. Listed twice it would be
  # enabled as <name>@local while claiming not to be a plugin — the marketplace
  # generator's manifest check would then silently decide which claim wins.
  assertions = [{
    assertion = lib.intersectLists cfg.plugins cfg.extraWorkspaceRepos == [];
    message = "dotfiles.claude: repo(s) in both plugins and extraWorkspaceRepos: "
      + lib.concatStringsSep ", " (lib.intersectLists cfg.plugins cfg.extraWorkspaceRepos);
  }];

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

  # 1b. Generate the `local` marketplace from the workspace clones.
  #
  #     Membership is decided by whether a repo carries
  #     .claude-plugin/plugin.json, not by a hand-kept list — reclaw is a
  #     workspace repo but not a plugin, and a second list would be one more
  #     thing to forget. Each entry is read from that manifest, so the
  #     marketplace cannot drift from the plugin it describes (the previously
  #     hand-written file had already drifted on cortex's description).
  home.activation.claudeLocalMarketplace =
    lib.hm.dag.entryAfter [ "claudePluginsWorkspace" ] ''
      export PATH="${lib.makeBinPath [ pkgs.jq pkgs.coreutils ]}:$PATH"
      mp="${localMarketplaceDir}"
      d="${pluginsDir}"
      mkdir -p "$mp/.claude-plugin" "$mp/plugins"

      entries='[]'
      ${lib.concatMapStringsSep "\n      " (r: ''
        if [ -f "$d/${r}/.claude-plugin/plugin.json" ]; then
          ln -sfn "$d/${r}" "$mp/plugins/${r}"
          entries="$(printf '%s' "$entries" | jq -c \
            --slurpfile p "$d/${r}/.claude-plugin/plugin.json" \
            --arg src "./plugins/${r}" \
            '. + [{ name: $p[0].name, description: $p[0].description, version: $p[0].version, author: $p[0].author, source: $src }]')"
        fi
      '') workspaceRepos}

      # Drop links for repos that stopped being plugins (or were removed), so a
      # stale entry can't keep advertising a plugin that no longer exists.
      for link in "$mp"/plugins/*; do
        [ -L "$link" ] || continue
        name="$(basename "$link")"
        [ -f "$d/$name/.claude-plugin/plugin.json" ] || rm -f "$link"
      done

      if printf '%s' "$entries" | jq -e 'length > 0' >/dev/null; then
        printf '%s' "$entries" | jq \
          '{ "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
             name: "local",
             description: "Local Claude Code plugins resolved live from ~/dev/claude-plugins/",
             owner: { name: "peterstorm" },
             plugins: . }' > "$mp/.claude-plugin/marketplace.json"
        echo "claude: local marketplace has $(printf '%s' "$entries" | jq length) plugin(s)"
      else
        echo "claude: WARNING no plugin manifests found in $d, left local marketplace untouched"
      fi
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

  };
}
