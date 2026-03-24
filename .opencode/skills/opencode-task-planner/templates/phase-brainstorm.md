# Brainstorm Phase — Artifact Format

This is an **orchestrator-driven** phase. The orchestrator asks the user questions via the `question` tool, gathers context, and writes this artifact directly. Do NOT spawn a brainstorm-agent.

---

## Brainstorm artifact format

Write the following to `.claude/specs/{date_slug}/brainstorm.md`:

```markdown
# Brainstorm: {feature_description}

## What we're building
{1-2 sentence summary of the feature/change}

## Motivation
{Why this work is needed — from user's answers}

## Selected approach
{The approach chosen from options explored with the user}

### Alternatives considered
{Other approaches discussed and why they were rejected}

## Key constraints
{Hard constraints, compatibility requirements, team/timeline limits}

## Open questions resolved
{Questions asked and user's answers, for traceability}

## Scope boundary
- **In scope:** {what's included}
- **Out of scope:** {what's explicitly excluded}
```

## Orchestrator checklist

Before writing the artifact, ensure you've explored:
- [ ] Motivation / pain points driving the work
- [ ] Technical constraints (compatibility, dependencies, deployment)
- [ ] User preferences (frameworks, tools, patterns)
- [ ] Scope boundaries (what's in, what's out)
- [ ] Incremental strategy (if applicable)
- [ ] Any prior decisions already made

After writing, advance phase:
```bash
bun ~/dev/claude-plugins/loom/engine/src/cli.ts helper set-phase --phase specify
```
