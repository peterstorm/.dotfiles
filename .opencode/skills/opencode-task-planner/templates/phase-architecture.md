# Architecture Phase Context

Template for spawning architecture-agent. Variables in `{braces}` must be substituted.

---

## Architecture: {feature_description}

**Spec:** {spec_file_path}

Design implementation approach for this feature.

**Output location:** `.opencode/plans/{date_slug}.md`

**Your output must include:**
- Path to created plan file
- Implementation phases identified
- Key architectural decisions with rationale

The architecture-agent has the `architecture-tech-lead` skill preloaded which guides design decisions.
