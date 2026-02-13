# Plan: Feynman Teaching Skill Plugin

## Context

User wants an interactive Feynman technique skill for Claude Code — when invoked on a concept (CS, architecture, or codebase-specific), Claude walks through the 4-step Feynman loop interactively: assess prior knowledge → teach simply with analogies → challenge with probing questions → refine weak spots. Codebase-aware: reads actual project code when the concept lives in the repo.

## Files to Create

### 1. Plugin manifest
**`.claude/plugins/feynman/.claude-plugin/plugin.json`**
```json
{
  "name": "feynman",
  "version": "0.1.0",
  "description": "Interactive Feynman technique teaching — learn any concept through simplified explanation, gap detection, and iterative refinement",
  "author": { "name": "peterstorm" }
}
```

### 2. Command skill
**`.claude/plugins/feynman/commands/feynman.md`**

Frontmatter:
- name: feynman
- version: 1.0.0
- description: interactive Feynman teaching for any concept
- allowed-tools: Read, Grep, Glob, AskUserQuestion

Sections:
- **Proactive trigger**: when user says "explain X", "I don't understand X", "teach me X", "what is X", or when user is visibly confused about a concept
- **Two modes**:
  - **Learn mode** (default) — Claude teaches using the 4-step Feynman loop
  - **Test mode** (`--test`) — user explains, Claude plays "curious student" asking "but why?" to surface gaps
- **Learn mode procedure** (4 steps):
  1. **ASSESS** — ask user what they already know (via AskUserQuestion). This primes recall and establishes baseline.
  2. **TEACH** — explain concept as if to a 12-year-old. MUST include: physical-world analogy, zero jargon (or define every term used), code example if applicable. If concept exists in the codebase, read the actual code and use it in the explanation.
  3. **CHALLENGE** — ask 2-3 probing questions that test understanding of the *why*, not just the *what*. Use AskUserQuestion with options that include common misconceptions as distractors.
  4. **REFINE** — based on answers, re-explain any weak spots with even simpler analogies. Summarize the concept in 1-2 sentences. Offer to go deeper on any sub-concept.
- **Test mode procedure**:
  1. Ask user to explain the concept in their own words
  2. Claude acts as confused student — asks "but why?" and "what do you mean by X?" on any jargon or hand-wavy parts
  3. Identifies specific gaps and points user to resources
  4. User re-explains, Claude confirms understanding or repeats
- **Codebase awareness**:
  - If concept matches something in the repo (pattern name, function, module), use Grep/Glob to find it
  - Use actual code snippets in the explanation alongside the analogy
  - Example: "/feynman 'our auth flow'" → reads auth code, explains it simply
- **Output format**: each step clearly labeled (Step 1: ASSESS, etc.), analogies in blockquotes, code in fenced blocks
- **When NOT to use**: trivial questions ("what's a variable?"), user explicitly wants terse answer
- **Integration**: after completing, optionally `/remember` the refined understanding via cortex

### 3. Marketplace registration

**Modify `.claude/local-marketplace/.claude-plugin/marketplace.json`** — add feynman entry to plugins array.

### 4. Symlink

**Create `.claude/local-marketplace/plugins/feynman`** → `../../plugins/feynman`

## Verification

1. `git add .` new files
2. Check plugin structure: `ls -la .claude/plugins/feynman/`
3. Verify symlink: `ls -la .claude/local-marketplace/plugins/feynman`
4. Install plugin: `claude /plugin install local`
5. Test invocation: `/feynman "closures"` in a session

## Unresolved Questions

- Want a `--quick` flag for single-shot (non-interactive) mode too?
- Should test mode also be codebase-aware (user explains code, Claude challenges)?
