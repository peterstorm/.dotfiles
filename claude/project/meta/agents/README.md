# Meta Agents

Agents for code review, architecture, and quality analysis.

## Shared agents (duplicated in loom plugin)

These agents exist in both this directory and the loom plugin
(`~/dev/claude-plugins/loom/agents/`) because symlinks are not supported
by the plugin cache. Changes must be synced manually.

**From this directory:**

| Agent | Loom copy |
|-------|-----------|
| `architecture-tech-lead.md` | `loom/agents/architecture-tech-lead.md` |
| `code-reviewer.md` | `loom/agents/code-reviewer.md` |
| `code-simplifier.md` | `loom/agents/code-simplifier.md` |
| `comment-analyzer.md` | `loom/agents/comment-analyzer.md` |
| `dotfiles-agent.md` | `loom/agents/dotfiles-agent.md` |
| `pr-test-analyzer.md` | `loom/agents/pr-test-analyzer.md` |
| `security-agent.md` | `loom/agents/security-agent.md` |
| `silent-failure-hunter.md` | `loom/agents/silent-failure-hunter.md` |
| `skill-content-reviewer.md` | `loom/agents/skill-content-reviewer.md` |
| `type-design-analyzer.md` | `loom/agents/type-design-analyzer.md` |

**From `../typescript/agents/`:**

| Agent | Loom copy |
|-------|-----------|
| `frontend-agent.md` | `loom/agents/frontend-agent.md` |
| `test-engineer.md` | `loom/agents/test-engineer.md` |
| `ts-test-agent.md` | `loom/agents/ts-test-agent.md` |

When editing a shared agent, update both copies and verify with:

```bash
diff ~/.dotfiles/claude/project/meta/agents/<name>.md ~/dev/claude-plugins/loom/agents/<name>.md
```

## Why agents are in both places

- **Dotfiles**: canonical source, versioned in dotfiles repo, used when agents
  are spawned directly from the main conversation (e.g., `/review-pr` in the
  main conversation).
- **Loom plugin**: copy required so subagents (e.g., `review-invoker`) can
  spawn them as `loom:code-reviewer`, `loom:silent-failure-hunter`, etc.
  The plugin cache doesn't follow symlinks.
