- In all interactions and commit messages, be extremely concise and sacrifice grammar for the sake of concision.

## Skill Invocation - CRITICAL

BEFORE writing code, MUST check if a relevant skill exists and invoke it FIRST:

| Trigger | Skill |
|---------|-------|
| "implement", "write code", "build", "create function" | `/code-implementer` |
| done implementing, ready to commit/push/PR | `/finalize` |
| review code, check PR, before merging | `/pr-review-toolkit:review-pr` |
| architectural decisions, design review | `/architecture-tech-lead` |

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
- When making multi-phase plans, create a Github Issue containing the FULL detailed plan:
  - All phases with goals and file lists (checkboxes for tracking)
  - Code examples and implementation details
  - Execution order table (effort/dependencies/risk)
  - Verification checklist
- Write the plan in plan mode as normal, then copy the ENTIRE plan content to the issue
- Update issue checkboxes as phases complete
- Link PRs to the issue
