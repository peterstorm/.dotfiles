# Skill Patterns

Choose a pattern based on use case. Claude knows these patterns — this is a quick-reference for naming and selection, not a tutorial.

| Pattern | When to Use | Key Technique |
|---------|-------------|---------------|
| **Sequential Workflow** | Multi-step processes in specific order | Explicit step ordering, validation gates, rollback on failure |
| **Multi-MCP Coordination** | Workflows spanning multiple services | Phase separation, data passing between MCPs, centralized error handling |
| **Iterative Refinement** | Output quality improves with iteration | Draft → validate → improve loop, quality thresholds, stopping conditions |
| **Context-Aware Selection** | Same outcome, different tools depending on context | Decision trees, fallback options, transparency about choices |
| **Domain Intelligence** | Skill adds specialized knowledge beyond tool access | Compliance checks before action, audit trails, governance rules |

Most skills combine 2-3 patterns. Start with Sequential Workflow as the backbone and layer others as needed.
