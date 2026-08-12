# Meta Agents

Project-scoped agents for the dotfiles repo. Symlink into a project's
`.claude/agents/` to use them.

## Contents

| Agent | Purpose |
|-------|---------|
| `dotfiles-agent.md` | NixOS/home-manager specialist for this repo (flake-parts, roles, SOPS) |

## Where the other agents went

The review/architecture/testing agents that used to be manually mirrored here
(code-reviewer, silent-failure-hunter, architecture-tech-lead, etc.) now live
**only in the loom plugin** (`~/dev/claude-plugins/loom/agents/`, installed from
`peterstorm/loom`). They surface as `loom:<name>` agents in every session — no
local copies, no manual sync.

For the Pi harness, Loom agents are **rendered per machine** rather than
tracked in git (see `pi/` and commit `36f2c99`); the renders are gitignored.

Editing a loom agent = edit in the loom repo, commit, push, then reinstall the
plugin (`claude plugin install loom@loom` or restart Claude Code after the
marketplace refreshes).
