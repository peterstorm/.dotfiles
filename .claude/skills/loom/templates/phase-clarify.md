# Clarify Phase Context

Template for spawning clarify-agent. Variables in `{braces}` must be substituted.

---

## CRITICAL: You CAN Write Files

**You are a subagent. PreToolUse hooks DO NOT apply to subagents (they bypass hooks entirely).**
- You MUST use Write/Edit tools to update the spec file — this WILL work
- Do NOT read `.claude/hooks/` or `.claude/state/` files — they are irrelevant to you
- Do NOT check if you are "allowed" to write — you are. Just write.

---

## Clarify: {spec_file_path}

Resolve uncertainties in the specification.

**Marker count:** {marker_count} `[NEEDS CLARIFICATION]` markers found

**Your output must include:**
- Updated spec.md with markers resolved
- Remaining marker count
- Summary of decisions made

The clarify-agent has the `clarify` skill preloaded which guides the questioning process.
