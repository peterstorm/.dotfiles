# Specify Phase Context

Template for spawning specify-agent. Variables in `{braces}` must be substituted.

---

## Specify: {feature_description}

{brainstorm_output}

Create formal specification for this feature.

**Output location:** `.claude/specs/{date_slug}/spec.md`

**Your output must include:**
- Path to created spec file
- Count of `[NEEDS CLARIFICATION]` markers
- Summary of key requirements (FR-xxx list)

The specify-agent has the `specify` skill preloaded which defines the spec format and process.
