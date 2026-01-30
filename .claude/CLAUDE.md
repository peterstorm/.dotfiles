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
See @rules/architecture.md for core principles (FP, DDD, immutability, testability).
For deep architectural review: `/architecture-tech-lead`

## Plans
- At the end of each plan, give me a list of unresolved questions, if any, to help make the plan more concise.
Make the questions extremely concise. Sacrifice grammer for the sake of concision.

## Multi-phase plans
Use `/task-planner` for automated orchestration:
- Decomposes tasks, assigns agents, schedules waves
- Creates GitHub Issue with full plan + checkboxes
- Hooks auto-update checkboxes on task completion
- Hooks auto-link PRs to issue

Manual fallback (if not using task-planner):
- Create Github Issue with FULL detailed plan
- Update issue checkboxes as phases complete
- Link PRs to the issue
