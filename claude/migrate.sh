#!/usr/bin/env bash
# Migration: .claude -> claude (no dot) to eliminate context bloat

set -euo pipefail

OLD=~/.dotfiles/.claude
NEW=~/.dotfiles/claude

echo "Creating folder structure..."
mkdir -p "$NEW"/{global,config,automation,session,plugins}
mkdir -p "$NEW/project"/{java,typescript,meta}
mkdir -p "$NEW/project/marketing"/{acquisition,conversion,retention,strategy}

# Marketing - Acquisition
echo "Organizing marketing/acquisition..."
for skill in marketing-content-strategy marketing-seo-audit marketing-programmatic-seo \
             marketing-paid-ads marketing-social-content marketing-schema-markup \
             marketing-competitor-alternatives marketing-free-tool-strategy marketing-referral-program; do
  [[ -d "$OLD/skills/$skill" ]] && cp -r "$OLD/skills/$skill" "$NEW/project/marketing/acquisition/"
done

# Marketing - Conversion
echo "Organizing marketing/conversion..."
for skill in marketing-ab-test-setup marketing-analytics-tracking marketing-copywriting \
             marketing-copy-editing marketing-form-cro marketing-page-cro marketing-popup-cro \
             marketing-signup-flow-cro marketing-pricing-strategy conversion-copy ux-conversion; do
  [[ -d "$OLD/skills/$skill" ]] && cp -r "$OLD/skills/$skill" "$NEW/project/marketing/conversion/"
done

# Marketing - Retention
echo "Organizing marketing/retention..."
for skill in marketing-onboarding-cro marketing-email-sequence marketing-paywall-upgrade-cro \
             marketing-product-marketing-context; do
  [[ -d "$OLD/skills/$skill" ]] && cp -r "$OLD/skills/$skill" "$NEW/project/marketing/retention/"
done

# Marketing - Strategy
echo "Organizing marketing/strategy..."
for skill in marketing-launch-strategy marketing-marketing-ideas marketing-marketing-psychology; do
  [[ -d "$OLD/skills/$skill" ]] && cp -r "$OLD/skills/$skill" "$NEW/project/marketing/strategy/"
done

# Java
echo "Organizing project/java..."
for skill in java-test-engineer entity-generator keycloak-skill k8s-expert; do
  [[ -d "$OLD/skills/$skill" ]] && cp -r "$OLD/skills/$skill" "$NEW/project/java/"
done

# TypeScript
echo "Organizing project/typescript..."
for skill in ts-test-engineer nextjs-frontend-design vercel-react-best-practices remotion-best-practices; do
  [[ -d "$OLD/skills/$skill" ]] && cp -r "$OLD/skills/$skill" "$NEW/project/typescript/"
done

# Meta (cross-cutting, potential future globals)
echo "Organizing project/meta..."
for skill in architecture-tech-lead review-skill security-expert mcp-expert \
             writing-clearly-and-concisely yt-summary dotfiles-expert find-skills idea-analyzer; do
  [[ -d "$OLD/skills/$skill" ]] && cp -r "$OLD/skills/$skill" "$NEW/project/meta/"
done

# Config files
echo "Copying config..."
[[ -f "$OLD/CLAUDE.md" ]] && cp "$OLD/CLAUDE.md" "$NEW/config/"
[[ -f "$OLD/settings.json" ]] && cp "$OLD/settings.json" "$NEW/config/"
[[ -f "$OLD/settings.local.json" ]] && cp "$OLD/settings.local.json" "$NEW/config/"
[[ -d "$OLD/rules" ]] && cp -r "$OLD/rules" "$NEW/config/"

# Automation
echo "Copying automation..."
[[ -d "$OLD/hooks" ]] && cp -r "$OLD/hooks" "$NEW/automation/"
[[ -d "$OLD/agents" ]] && cp -r "$OLD/agents" "$NEW/automation/"
[[ -d "$OLD/commands" ]] && cp -r "$OLD/commands" "$NEW/automation/"
[[ -f "$OLD/statusline-command.sh" ]] && cp "$OLD/statusline-command.sh" "$NEW/automation/"

# Session state
echo "Copying session state..."
[[ -d "$OLD/plans" ]] && cp -r "$OLD/plans" "$NEW/session/"
[[ -d "$OLD/ideas" ]] && cp -r "$OLD/ideas" "$NEW/session/"
[[ -d "$OLD/state" ]] && cp -r "$OLD/state" "$NEW/session/"
[[ -d "$OLD/notes" ]] && cp -r "$OLD/notes" "$NEW/session/"
[[ -d "$OLD/archives" ]] && cp -r "$OLD/archives" "$NEW/session/"
[[ -f "$OLD/cortex-memory.local.md" ]] && cp "$OLD/cortex-memory.local.md" "$NEW/session/"

# Loom plugin
echo "Linking loom plugin..."
ln -sfn ~/dev/claude-plugins/loom "$NEW/plugins/loom"

# Move loom artifacts
echo "Moving loom artifacts to plugin..."
mkdir -p ~/dev/claude-plugins/loom/artifacts
[[ -d "$OLD/specs" ]] && mv "$OLD/specs" ~/dev/claude-plugins/loom/artifacts/ 2>/dev/null || true
[[ -d "$OLD/reviews" ]] && mv "$OLD/reviews" ~/dev/claude-plugins/loom/artifacts/ 2>/dev/null || true
[[ -d "$OLD/tests" ]] && mv "$OLD/tests" ~/dev/claude-plugins/loom/artifacts/ 2>/dev/null || true

# Preserve plugins metadata (don't copy actual plugin content)
echo "Preserving plugin metadata..."
[[ -d "$OLD/plugins" ]] && cp -r "$OLD/plugins" "$NEW/session/plugins-metadata"

cat > "$NEW/README.md" << 'EOF'
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
EOF

echo ""
echo "✅ Migration complete!"
echo ""
echo "Structure:"
tree -L 3 -d "$NEW" 2>/dev/null || find "$NEW" -type d -maxdepth 3
echo ""
echo "Next: Review structure, then:"
echo "  1. Test symlinks: ln -sfn ~/.dotfiles/claude/project/meta/* ~/.claude/skills/"
echo "  2. Verify Claude loads correctly"
echo "  3. Delete old: rm -rf ~/.dotfiles/.claude/skills (after confirmed working)"
