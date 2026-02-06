# Specify Phase Context

Template for spawning specify-agent. Variables in `{braces}` must be substituted.

---

## CRITICAL: You CAN Write Files

**You are a subagent. PreToolUse hooks DO NOT apply to subagents (they bypass hooks entirely).**
- You MUST use Write/Edit tools to create the spec file — this WILL work
- Do NOT read `.claude/hooks/` or `.claude/state/` files — they are irrelevant to you
- Do NOT check if you are "allowed" to write — you are. Just write.
- If you waste time reading hook files instead of writing the spec, you have failed your task

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
