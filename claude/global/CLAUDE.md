- In all interactions and commit messages, be extremely concise and sacrifice grammar for the sake of concision.

## Skill Invocation - CRITICAL

Do NOT skip skills because you "know how" - skills ensure consistency and best practices.

## PR comments
<pr-comment-rule>
When I say to add a comment to a PR with a TODO on it, use the Github 'checkbox' markdown format to add the TODO. For instance:

<example>
- [ ] a description of the TODO goes here
</example>
</pr-comment-rule>

## Github
- Your primary way of interacting with Github should be via the github cli
- Don't finish commit or pr message with "Generated with Claude Code"

## Git
- when braching, remember to always prefix branches with `feature`, `bugfix`, etc

## Architecture
See @project/meta/rules/architecture.md for core principles (FP, DDD, immutability, testability).
For deep architectural review: `/architecture-tech-lead`

## Project-specific skills, agents, rules

Domain-specific config lives in `~/.dotfiles/claude/project/<domain>/`. Activate per-project by symlinking into the project's `.claude/`:

```bash
# available domains: java, typescript, meta, marketing
DOMAIN=java
ln -s ~/.dotfiles/claude/project/$DOMAIN/skills .claude/skills
ln -s ~/.dotfiles/claude/project/$DOMAIN/agents .claude/agents
ln -s ~/.dotfiles/claude/project/$DOMAIN/rules .claude/rules
```

For multi-domain projects, symlink individual items instead:
```bash
mkdir -p .claude/skills .claude/agents .claude/rules
ln -s ~/.dotfiles/claude/project/java/skills/* .claude/skills/
ln -s ~/.dotfiles/claude/project/java/agents/* .claude/agents/
ln -s ~/.dotfiles/claude/project/java/rules/* .claude/rules/
ln -s ~/.dotfiles/claude/project/meta/agents/* .claude/agents/
ln -s ~/.dotfiles/claude/project/meta/rules/* .claude/rules/
```

Generic agents (code-reviewer, code-simplifier, etc.) dynamically load domain rules based on file types — no static config needed.

## Plans
- At the end of each plan, give me a list of unresolved questions, if any, to help make the plan more concise.
Make the questions extremely concise. Sacrifice grammer for the sake of concision.

## Multi-phase plans
Use `/loom` for automated orchestration:
- Decomposes tasks, assigns agents, schedules waves
- Creates GitHub Issue with full plan + checkboxes
- Hooks auto-update checkboxes on task completion
- Hooks auto-link PRs to issue

Manual fallback (if not using loom):
- Create Github Issue with FULL detailed plan
- Update issue checkboxes as phases complete
- Link PRs to the issue
