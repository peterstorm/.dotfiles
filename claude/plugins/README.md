# Claude Plugins

Plugins are **individual git repos** (`peterstorm/{loom,cortex,feynman}`), each
its own one-plugin marketplace (`.claude-plugin/marketplace.json` with
`"source": "."`), installed from GitHub — not from a local directory.

The wiring is managed declaratively by home-manager:

- `roles/home-manager/core-apps/claude/default.nix` — provisions the repos into
  `~/dev/claude-plugins/` and deep-merges `extraKnownMarketplaces` +
  `enabledPlugins` into `~/.claude/settings.json`.
- `roles/home-manager/core-apps/git/default.nix` — rewrites the SSH URL of each
  of these three public repos → HTTPS so they clone without an SSH key. Scoped
  per repo, never namespace-wide: a `peterstorm/*` rewrite would also hijack the
  private repos in that namespace and break their authenticated pushes.

See `../README.md` → "Plugins" for the full explanation.
