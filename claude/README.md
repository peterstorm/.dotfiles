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

Plugins live in `~/dev/claude-plugins/` and are symlinked into `plugins/`. Enabled in `global/settings.json` under `enabledPlugins`:

```json
{
  "enabledPlugins": {
    "cortex@plugins": true,
    "loom@plugins": true,
    "obsidian@plugins": true,
    "feynman@plugins": true
  }
}
```

To add a new plugin:

```bash
# Clone/create the plugin
cd ~/dev/claude-plugins
git clone <plugin-repo> my-plugin

# Symlink into dotfiles
ln -s ~/dev/claude-plugins/my-plugin ~/.dotfiles/claude/plugins/my-plugin

# Enable in settings.json — add "my-plugin@plugins": true to enabledPlugins
```

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
