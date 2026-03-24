# Clarify Phase — Orchestrator Guide

This is an **orchestrator-driven** phase. The orchestrator reads `[NEEDS CLARIFICATION]` markers from the spec, asks the user to resolve them via the `question` tool, and edits the spec directly. Do NOT spawn a clarify-agent.

---

## Steps

1. **Extract markers** from the spec file:
   ```bash
   grep -n "NEEDS CLARIFICATION" <spec_file_path>
   ```

2. **For each marker**, present the context to the user and ask them to decide using the `question` tool:
   - Show the marker text and surrounding spec context
   - Propose options if reasonable choices can be inferred
   - Group related markers into single questions where possible

3. **Edit the spec** to replace each marker with the user's definitive decision. The resolved text should read as a firm requirement.

4. **Verify** zero markers remain:
   ```bash
   grep -c "NEEDS CLARIFICATION" <spec_file_path>
   ```

5. **Advance phase**:
   ```bash
   bun ~/dev/claude-plugins/loom/engine/src/cli.ts helper set-phase --phase architecture
   ```

## Output

- Updated `spec.md` with all markers resolved
- Summary of decisions made (presented to user before advancing)
