# Claude Code Dotfiles

Modular Claude Code configuration with domain-specific skills, rules, agents, and plugin infrastructure. Managed via symlinks so each project loads only what it needs.

## Structure

```
~/.dotfiles/claude/
├── global/                     # Shared across ALL projects
│   ├── CLAUDE.md               # Global instructions (symlinked to ~/.claude/CLAUDE.md)
│   ├── settings.json           # Global settings + hooks (symlinked to ~/.claude/settings.json)
│   ├── hooks/                  # Hook scripts (cortex, event dispatch, etc.)
│   └── skills/                 # Universal skills (brainstorming, writing)
│
├── project/                    # Domain-specific configs
│   ├── java/                   # Java/Spring Boot
│   │   ├── skills/             # entity-generator, etc.
│   │   ├── agents/
│   │   └── rules/              # java-patterns.md, property-testing.md
│   ├── typescript/             # TypeScript/Next.js/React
│   │   ├── skills/             # nextjs-frontend-design, ts-test-engineer, vercel-react, etc.
│   │   ├── agents/
│   │   └── rules/
│   ├── meta/                   # Cross-domain tooling
│   │   ├── skills/             # architecture-tech-lead, skill-creator, skill-content-reviewer, etc.
│   │   ├── agents/
│   │   └── rules/              # architecture.md
│   ├── rust/                   # Rust
│   │   ├── skills/
│   │   ├── agents/
│   │   └── rules/              # rust-patterns.md
│   └── marketing/              # Marketing/CRO
│       └── skills/             # acquisition/, conversion/, retention/, strategy/
│
└── plugins/                    # Plugin symlinks → ~/dev/claude-plugins/
    ├── cortex                  # Persistent semantic memory
    ├── loom                    # Multi-phase task orchestration
    ├── obsidian                # Vault management
    └── feynman                 # Interactive teaching
```

## Setup

### 1. Global config (one-time)

Symlink global files into `~/.claude/`:

```bash
ln -sf ~/.dotfiles/claude/global/CLAUDE.md ~/.claude/CLAUDE.md
ln -sf ~/.dotfiles/claude/global/settings.json ~/.claude/settings.json
ln -sf ~/.dotfiles/claude/global/settings.local.json ~/.claude/settings.local.json
```

### 2. Per-project: single domain

For a project using one domain, symlink the entire directories:

```bash
cd /path/to/my-project
mkdir -p .claude

DOMAIN=java  # java | typescript | meta | rust | marketing
ln -s ~/.dotfiles/claude/project/$DOMAIN/skills .claude/skills
ln -s ~/.dotfiles/claude/project/$DOMAIN/agents .claude/agents
ln -s ~/.dotfiles/claude/project/$DOMAIN/rules .claude/rules
```

### 3. Per-project: multi-domain

For projects needing configs from multiple domains, symlink individual items:

```bash
cd /path/to/my-project
mkdir -p .claude/skills .claude/agents .claude/rules

# Java skills + rules
ln -s ~/.dotfiles/claude/project/java/skills/* .claude/skills/
ln -s ~/.dotfiles/claude/project/java/rules/* .claude/rules/

# Meta agents + skills (architecture, code review, etc.)
ln -s ~/.dotfiles/claude/project/meta/skills/* .claude/skills/
ln -s ~/.dotfiles/claude/project/meta/agents/* .claude/agents/
ln -s ~/.dotfiles/claude/project/meta/rules/* .claude/rules/
```

### 4. Per-project: cherry-pick specific skills

Symlink only the skills you want:

```bash
mkdir -p .claude/skills
ln -s ~/.dotfiles/claude/project/meta/skills/architecture-tech-lead .claude/skills/
ln -s ~/.dotfiles/claude/project/typescript/skills/ts-test-engineer .claude/skills/
```

## Plugins

Each Claude Code plugin is its **own git repo** that doubles as a one-plugin
*marketplace* (`.claude-plugin/marketplace.json` with `"source": "."`):

| Plugin  | Repo                |
|---------|---------------------|
| loom    | `peterstorm/loom`   |
| cortex  | `peterstorm/cortex` |
| feynman | `peterstorm/feynman`|

They install **from git**, not a local directory, and the whole wiring is
managed by home-manager — a fresh machine just needs `hm-apply`.

### How it's wired (home-manager)

`roles/home-manager/core-apps/claude/default.nix`:

1. **Provisions the workspace** — clones `loom`, `cortex`, `feynman`, `reclaw`
   into `~/dev/claude-plugins/` (idempotent). Other tools (pi, opencode, reclaw)
   read these repos directly off disk.
2. **Manages `~/.claude/settings.json`** — deep-merges `enabledPlugins`
   (`loom@loom`, `cortex@cortex`, `feynman@feynman`) and `extraKnownMarketplaces`
   (each → its GitHub repo) into the live file, preserving runtime-written keys.

`roles/home-manager/core-apps/git/default.nix` rewrites
`git@github.com:peterstorm/*` → HTTPS, so the **public** plugin repos clone
without an SSH key (GitHub SSH always needs a key, even for public repos; HTTPS
does not).

After `hm-apply`, restart Claude Code: the declared marketplaces register and the
enabled plugins install automatically.

### Manual equivalent (reference / bootstrap)

```bash
# register a plugin repo as its own marketplace, then install it
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
mkdir -p ~/.dotfiles/claude/project/$DOMAIN/{skills,agents,rules}
```

Then add skills (folders with `SKILL.md`), agents, and rules. Use `/skill-creator` to scaffold new skills, `/skill-content-reviewer` to audit them.

## Hooks

Global hooks registered in `global/settings.json`, scripts in `global/hooks/`. The `send_event.sh` hook dispatches events to all enabled plugins (cortex, loom, etc.) across all lifecycle events (SessionStart, PreToolUse, PostToolUse, Stop, etc.).

## Key skills

| Skill | Domain | Purpose |
|-------|--------|---------|
| `/architecture-tech-lead` | meta | Architectural review + testability |
| `/skill-creator` | meta | Scaffold new skills |
| `/skill-content-reviewer` | meta | Audit skills against Agent Skills spec |
| `/review-skill` | meta | Multi-agent parallel skill review |
| `/loom` | plugin | Multi-phase task orchestration |
| `/brainstorming` | global | Pre-implementation design exploration |

## How it connects

```
~/.claude/CLAUDE.md        ──>  ~/.dotfiles/claude/global/CLAUDE.md
~/.claude/settings.json    ──>  ~/.dotfiles/claude/global/settings.json

project/.claude/skills/    ──>  ~/.dotfiles/claude/project/{domain}/skills/*
project/.claude/rules/     ──>  ~/.dotfiles/claude/project/{domain}/rules/*
project/.claude/agents/    ──>  ~/.dotfiles/claude/project/{domain}/agents/*
```

Claude Code loads `~/.claude/` globally, then merges project-level `.claude/` on top. Skills, rules, and agents activate based on what's symlinked — no config files to edit per project.
