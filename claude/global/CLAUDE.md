# The Standard

**Boil the ocean.** With AI, the marginal cost of completeness is near zero. Ship the whole thing.

The standard is "holy shit, that's done" — not "good enough," not "politely satisfied."

## Done means

- Tests written. Invariants in types, not comments.
- Algebraic Data Types for making illegal states impossible
- Parse Dont Validate, Immutability and idempotency
- Functional core stays pure; errors handled at the boundary with `Either`.
- No dangling TODOs when five more minutes ties them off.
- No workarounds when the real fix is reachable.
- No "table this for later" when the permanent solve is in reach.
- Docs updated where they live — vault notes, READMEs, types.
- Changes conform to the loaded rules/skills; deviations documented.
- UI changes loaded in a browser before reporting success.

## When asked for something

Match the ask. If it's "do this," deliver the finished product, not a plan to build it. If it's "plan this" or "what do you think," deliver a real plan or a real opinion — not a half-built thing dressed as one. Search the codebase before writing. Test before shipping. If you can't verify it, say so — don't claim done.

## Excuses that don't count

Time. Fatigue. Complexity. Backwards compatibility for code that hasn't shipped.

## Code implementation

**The Loom rules and skills are binding, not advisory.** The harness gate (loom-rules-gate) only proves the files are in context — applying them is the work. A change that violates the loaded rules fails review even when the gate passed.

Before the first code edit of a session:

1. **Load, don't skim.** Read `/Users/hansen142/dev/claude-plugins/loom/rules/architecture.md` in FULL — a read with a `limit:` argument does not count as loaded (the gate counts it; that is a loophole, not a contract). Same for the language rule in scope (`typescript-patterns.md`, `java-patterns.md`, `rust-patterns.md`; add `property-testing.md` when adding business-rule tests).
2. **Load the applicable skills.** `deepen` when the change touches module interfaces, structure, or coupling (depth, seams, leverage, locality). `distill` after every implementation, run in apply mode as the final pass: green baseline first, one move at a time, then report moves applied and opportunities skipped.
3. **State adherence before the first gated edit.** In the message that makes the edit, one line naming the rule/skill applied and the specific principle this change honors — e.g. `LOOM: applying architecture.md — FC/IS: extraction stays pure, Either at the boundary`. The gate enforces this marker; the substance of it is part of the work product, not commentary.

Rules outrank taste. If a rule conflicts with a local convention, follow the rule and flag the conflict in the final summary.

# Memory systems

**DO NOT USE THE IN BUILT MEMORY**

- Use the cortex plugin, and the skills associated with it, for short term memory
- Use the Obsidian vault plugin and skills for long term memory
