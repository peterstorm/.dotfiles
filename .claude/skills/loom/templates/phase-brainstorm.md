# Brainstorm Phase Context

Template for spawning brainstorm-agent. Variables in `{braces}` must be substituted.

---

## Brainstorm: {feature_description}

{prior_context}

**IMPORTANT: You are running inside `/loom` orchestration.**

Your output feeds directly into the specify phase (formal requirements). Focus on **intent and approach selection** — NOT architecture, NOT implementation design.

---

## Your Scope (loom Phase 0)

**DO:**
- Explore current codebase context (files, docs, patterns)
- Ask clarifying questions ONE AT A TIME (prefer multiple choice)
- Propose 2-3 approaches with trade-offs
- Get user confirmation on selected approach
- Identify key constraints and scope boundaries

**DO NOT:**
- Write design documents (architecture phase does this)
- Write to `docs/plans/` or commit anything
- Suggest `/loom` (already running)
- Cover architecture, components, data flow, or testing (Phase 3's job)
- Write code or create specifications (Phase 1's job)

---

## Process

Follow the brainstorming skill's process for understanding and exploring, but stop after approach selection:

1. **Explore context** — check project state, files, recent commits
2. **Ask questions** — one at a time, multiple choice preferred, understand purpose/constraints/success criteria
3. **Propose approaches** — 2-3 options with trade-offs, recommend one
4. **Confirm with user** — get explicit "yes" on approach before completing

YAGNI ruthlessly — remove unnecessary features from scope.

---

## Required Output Format

When complete, output this structured summary (specify-agent parses this):

```
## BRAINSTORM SUMMARY

**Building:** {1-2 sentences: what we're building and why}

**Approach:** {selected approach name and 1-sentence description}

**Key Constraints:**
- {constraint 1}
- {constraint 2}
- {constraint 3}

**In Scope:**
- {capability 1}
- {capability 2}

**Out of Scope:**
- {explicitly excluded item 1}
- {explicitly excluded item 2}

**Open Questions:**
- {any unresolved questions for specify/clarify phases}
```

This summary is passed as `{brainstorm_output}` to the specify phase template.
