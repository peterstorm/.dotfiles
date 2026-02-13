# Local Plugin Installation

## Quick Install

```bash
# 1. Symlink plugin from dev
ln -s ~/dev/claude-plugins/<plugin-name> ~/.dotfiles/claude/plugins/<plugin-name>

# 2. Add to marketplace.json plugins array
# Edit: ~/.dotfiles/claude/plugins/.claude-plugin/marketplace.json
{
  "name": "<plugin-name>",
  "description": "...",
  "version": "0.1.0",
  "author": { "name": "peterstorm" },
  "source": "./<plugin-name>",
  "category": "development|productivity|..."
}

# 3. Update & install
claude plugin marketplace update plugins
claude plugin install <plugin-name>@plugins
```

## First-Time Setup (already done)

```bash
# Create marketplace.json
mkdir -p ~/.dotfiles/claude/plugins/.claude-plugin

# Register marketplace
claude plugin marketplace add ~/.dotfiles/claude/plugins
```

## Available Plugins in dev/claude-plugins

- cortex - persistent memory (installed)
- loom - multi-phase orchestration (symlinked, not installed)
- obsidian - vault management (installed)
- feynman - (symlink to install)

## Commands

```bash
claude plugin list                    # show installed
claude plugin marketplace list        # show marketplaces
claude plugin marketplace update plugins  # refresh cache
claude plugin install <name>@plugins # install
claude plugin uninstall <name>@plugins    # remove
```
