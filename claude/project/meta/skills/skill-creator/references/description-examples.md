# Description Field Examples

The `description` in YAML frontmatter is how Claude decides whether to load a skill. It's the most important field.

**Structure:** `[What it does] + [When to use it] + [Key capabilities]`

---

## Good Descriptions

```yaml
# Specific, actionable, includes trigger phrases
description: "Analyzes Figma design files and generates developer handoff documentation. Use when user uploads .fig files, asks for 'design specs', 'component documentation', or 'design-to-code handoff'."

# Includes trigger phrases and scope
description: "Manages Linear project workflows including sprint planning, task creation, and status tracking. Use when user mentions 'sprint', 'Linear tasks', 'project planning', or asks to 'create tickets'."

# Clear value prop + triggers
description: "End-to-end customer onboarding workflow for PayFlow. Handles account creation, payment setup, and subscription management. Use when user says 'onboard new customer', 'set up subscription', or 'create PayFlow account'."

# This project's pattern — explicit "should be used when"
description: "This skill should be used when the user asks to 'review my architecture', 'improve testability', 'refactor for testing', or needs architectural validation for Java/Spring Boot or TypeScript/Next.js codebases."
```

## Bad Descriptions

```yaml
# Too vague — won't trigger correctly
description: "Helps with projects."

# Missing triggers — Claude won't know WHEN
description: "Creates sophisticated multi-page documentation systems."

# Too technical, no user-facing triggers
description: "Implements the Project entity model with hierarchical relationships."

# Missing WHAT — only has triggers
description: "Use when user says 'do the thing'."
```

## This Project's Convention

Skills in this dotfiles project use a consistent pattern:

```yaml
description: "This skill should be used when the user asks to '[verb phrase 1]', '[verb phrase 2]', '[verb phrase 3]', or [broader condition]. [One sentence of what it does]."
```

Always match this pattern for consistency.
