# Claude Code Dotfiles

Modular Claude Code configuration with domain-specific skills, rules, agents, and plugin infrastructure. Managed via symlinks so each project loads only what it needs.

## Structure

```
~/.dotfiles/claude/
├── global/                     # Shared across ALL projects
│   ├── CLAUDE.md               # Global instructions (symlinked to ~/.claude/CLAUDE.md)
│   ├── skills/                 # Universal skills (writing-clearly-and-concisely)
│   └── statusline-command.sh   # Status line (wired via settings.json statusLine)
│
├── project/                    # Domain-specific configs
│   ├── java/
│   │   └── skills/             # entity-generator
│   ├── typescript/
│   │   ├── skills/             # remotion skill pack (router + sub-skills)
│   │   └── rules/              # typescript-patterns.md
│   ├── meta/                   # Cross-domain tooling
│   │   ├── skills/             # skill-creator, skill-content-reviewer, mcp-expert,
│   │   │                       # idea-analyzer, calendar-add, crossfit-coach, ...
│   │   ├── agents/             # dotfiles-agent (repo-specific)
│   │   ├── commands/           # finalize
│   │   └── rules/              # architecture.md
│   └── marketing/              # Marketing/CRO pack (vendored from
│       └── skills/             # coreyhaines31/marketingskills)
│
├── docs/                       # agents-vs-skills.md
└── plugins/                    # README only — see Plugins below
```

Note: general-purpose review/architecture/testing skills and agents
(brainstorming, architecture-tech-lead, review-pr, code-reviewer, vercel-react
best practices, …) live in the **loom plugin**, not here. This tree only keeps
what loom doesn't ship.

## Setup

### 1. Global config (one-time)

```bash
ln -sf ~/.dotfiles/claude/global/CLAUDE.md ~/.claude/CLAUDE.md
ln -sf ~/.dotfiles/claude/global/skills/writing-clearly-and-concisely ~/.claude/skills/
```

`~/.claude/settings.json` is **not** symlinked — home-manager deep-merges the
declared keys (plugins, marketplaces) into the live file and Claude Code writes
runtime keys to it. See "How it's wired" below.

### 2. Per-project: cherry-pick what the project needs

```bash
cd /path/to/my-project
mkdir -p .claude/skills .claude/rules .claude/agents

# examples
ln -s ~/.dotfiles/claude/project/typescript/skills/* .claude/skills/
ln -s ~/.dotfiles/claude/project/typescript/rules/* .claude/rules/
ln -s ~/.dotfiles/claude/project/meta/skills/mcp-expert .claude/skills/
ln -s ~/.dotfiles/claude/project/meta/agents/dotfiles-agent.md .claude/agents/
```

Symlink whole domain directories only when the project genuinely uses
everything in them; cherry-picking keeps the skill index lean.

## Plugins

Each Claude Code plugin is its **own git repo** that doubles as a one-plugin
*marketplace* (`.claude-plugin/marketplace.json` with `"source": "."`):

| Plugin  | Repo                 | Installed as |
|---------|----------------------|--------------|
| loom    | `peterstorm/loom`    | `loom@loom` (GitHub marketplace) |
| cortex  | `peterstorm/cortex`  | `cortex@cortex` (GitHub marketplace) |
| feynman | `peterstorm/feynman` | `feynman@feynman` (GitHub marketplace) |
| obsidian| local only           | `obsidian@plugins` (directory marketplace `~/dev/claude-plugins`) |

### How it's wired (home-manager)

`roles/home-manager/core-apps/claude/default.nix`:

1. **Provisions the workspace** — clones `loom`, `cortex`, `feynman`, `reclaw`
   into `~/dev/claude-plugins/` (idempotent). Other tools (pi, opencode, reclaw)
   read these repos directly off disk.
2. **Manages `~/.claude/settings.json`** — deep-merges `enabledPlugins`
   (`loom@loom`, `cortex@cortex`, `feynman@feynman`) and `extraKnownMarketplaces`
   (each → its GitHub repo) into the live file, preserving runtime-written keys.

`roles/home-manager/core-apps/git/default.nix` rewrites the SSH URL of each
**public** plugin repo (`loom`, `cortex`, `feynman`) → HTTPS, so they clone
without an SSH key (GitHub SSH always needs a key, even for public repos; HTTPS
does not).

The rewrite is listed per repo rather than as a `git@github.com:peterstorm/*`
namespace glob on purpose. A namespace-wide rule also captures the **private**
repos there — notably the Obsidian vault at `~/dev/notes` — pointing their
working SSH remotes at an HTTPS endpoint with no credential helper. Interactive
git then asks for a username; the `obsidian-git-sync` systemd timer, having no
tty, just fails with `could not read Username for 'https://github.com'`.

Only SSH remotes get hijacked. This dotfiles repo is unaffected — its remote is
HTTPS with a repo-local `!gh auth git-credential` helper.

After `hm-apply`, restart Claude Code: the declared marketplaces register and the
enabled plugins install automatically.

### Editing a plugin

Plugins install from GitHub, so local edits in `~/dev/claude-plugins/<name>`
don't take effect until committed, pushed, and reinstalled:

```bash
cd ~/dev/claude-plugins/loom && git commit -am "..." && git push
claude plugin install loom@loom   # or restart Claude Code
```

### Manual equivalent (reference / bootstrap)

```bash
claude plugin marketplace add peterstorm/loom
claude plugin install loom@loom

claude plugin list
claude plugin marketplace list
```

### Adding a new plugin

1. Create the plugin repo with both `.claude-plugin/plugin.json` and
   `.claude-plugin/marketplace.json` (marketplace `name` = plugin name, one
   plugin entry, `"source": "."`).
2. Add it to `workspaceRepos`, `enabledPlugins`, and `extraKnownMarketplaces` in
   `core-apps/claude/default.nix`.
3. `hm-apply`, then restart Claude Code.

## Adding new domain configs

```bash
DOMAIN=go
mkdir -p ~/.dotfiles/claude/project/$DOMAIN/skills
```

Add `rules/` or `agents/` subdirs only when there is content for them. Use
`/skill-creator` to scaffold new skills, `/skill-content-reviewer` to audit them.

## Hooks

No hooks are registered from this tree. Runtime hooks (memory surface, recall)
come from the **cortex plugin**, which registers its own hooks on install.

## Key skills

| Skill | Home | Purpose |
|-------|------|---------|
| `/skill-creator` | meta | Scaffold new skills |
| `/skill-content-reviewer` | meta | Audit skills against Agent Skills spec |
| `/review-skill` | meta | Multi-agent parallel skill review |
| `/mcp-expert` | meta | MCP server design + review |
| `/loom` | loom plugin | Multi-phase task orchestration |
| `/loom:brainstorming` | loom plugin | Pre-implementation design exploration |
| `/loom:architecture-tech-lead` | loom plugin | Architectural design + review |
| `/writing-clearly-and-concisely` | global | Prose quality (Strunk) |

## How it connects

```
~/.claude/CLAUDE.md        ──>  ~/.dotfiles/claude/global/CLAUDE.md   (symlink)
~/.claude/settings.json         real file; home-manager merges declared keys
~/.claude/skills/*         ──>  ~/.dotfiles/claude/global/skills/*    (symlinks)

project/.claude/skills/    ──>  ~/.dotfiles/claude/project/{domain}/skills/*
project/.claude/rules/     ──>  ~/.dotfiles/claude/project/{domain}/rules/*
project/.claude/agents/    ──>  ~/.dotfiles/claude/project/{domain}/agents/*
```

Claude Code loads `~/.claude/` globally, then merges project-level `.claude/`
on top. Skills, rules, and agents activate based on what's symlinked — no
config files to edit per project.
