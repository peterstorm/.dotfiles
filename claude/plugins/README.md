# Claude Plugins

Plugins are **individual git repos** (`peterstorm/{loom,cortex,feynman}`), each
its own one-plugin marketplace (`.claude-plugin/marketplace.json` with
`"source": "."`), installed from GitHub — not from a local directory.

The wiring is managed declaratively by home-manager:

- `roles/home-manager/core-apps/claude/default.nix` — provisions the repos into
  `~/dev/claude-plugins/` and deep-merges `extraKnownMarketplaces` +
  `enabledPlugins` into `~/.claude/settings.json`.
- `roles/home-manager/core-apps/git/default.nix` — rewrites
  `git@github.com:peterstorm/*` → HTTPS so the public repos clone without an SSH key.

See `../README.md` → "Plugins" for the full explanation.
