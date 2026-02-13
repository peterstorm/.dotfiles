# Claude Configuration (Context-Free)

Organized to eliminate auto-loading bloat. Symlink selectively.

## Structure

- `global/` - Skills to symlink globally (TBD after trial period)
- `config/` - CLAUDE.md, settings, rules
- `automation/` - hooks, agents, commands
- `session/` - plans, ideas, state (working files)
- `project/` - Skills organized by tech/domain
  - `java/`, `typescript/`, `meta/`
  - `marketing/{acquisition,conversion,retention,strategy}/`
- `plugins/` - loom symlink

## Usage

Global symlink (once you identify must-haves):
```bash
ln -sfn ~/.dotfiles/claude/global/* ~/.claude/skills/
```

Project-specific:
```bash
# Java project
ln -sfn ~/.dotfiles/claude/project/java/* .claude/skills/

# Marketing site
ln -sfn ~/.dotfiles/claude/project/typescript/* .claude/skills/
ln -sfn ~/.dotfiles/claude/project/marketing/conversion/* .claude/skills/
```

Config symlinks:
```bash
ln -sfn ~/.dotfiles/claude/config/CLAUDE.md ~/.claude/
ln -sfn ~/.dotfiles/claude/config/settings.json ~/.claude/
```

## Migration Notes

Original .claude preserved until verified. Safe to delete .claude/skills after testing.
