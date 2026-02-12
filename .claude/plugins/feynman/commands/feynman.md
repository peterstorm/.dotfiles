---
name: feynman
description: "Interactive Feynman technique teaching — explain any concept simply, detect gaps, refine understanding"
argument-hint: "[concept] [--test]"
allowed-tools: ["Read", "Grep", "Glob", "AskUserQuestion"]
---

Interactive Feynman technique for learning any concept — CS, architecture, or codebase-specific.

## Parse Arguments

- `$ARGUMENTS` contains the concept and optional flags
- If `--test` flag present → **Test mode**
- Otherwise → **Learn mode** (default)

## When NOT to Use

- Trivial questions ("what's a variable?") — answer directly instead
- User explicitly wants a terse answer — just answer

## Codebase Awareness

Before starting either mode, check if the concept maps to something in the repo:

1. Use Grep to search for the concept name in code (function names, module names, comments)
2. Use Glob to find related files
3. If matches found, read the relevant code — use actual snippets alongside analogies in explanations

Example: `/feynman "our auth flow"` → search for auth-related code, read it, explain it simply.

---

## Learn Mode (default)

Walk through the 4-step Feynman loop interactively.

### Step 1: ASSESS

**Goal**: prime recall, establish baseline.

Use AskUserQuestion to ask what the user already knows about the concept. Offer options ranging from "nothing" to "I use it daily but want deeper understanding".

Format output:
```
## Step 1: ASSESS
[question via AskUserQuestion]
```

### Step 2: TEACH

**Goal**: explain as if to a 12-year-old.

Rules:
- MUST include a physical-world analogy (blockquote format)
- Zero jargon — or define every term on first use
- If concept exists in the codebase, include actual code snippets in fenced blocks alongside the analogy
- Build from what the user already knows (from Step 1)

Format output:
```
## Step 2: TEACH

> **Analogy**: [physical-world analogy here]

[Simple explanation building on analogy...]

[Code example if applicable]
```

### Step 3: CHALLENGE

**Goal**: test understanding of the *why*, not just the *what*.

Ask 2-3 probing questions using AskUserQuestion. Include common misconceptions as distractor options.

Format output:
```
## Step 3: CHALLENGE
[2-3 probing questions via AskUserQuestion]
```

### Step 4: REFINE

**Goal**: patch weak spots, cement understanding.

Based on challenge answers:
- Re-explain any wrong/uncertain answers with even simpler analogies
- Summarize the full concept in 1-2 sentences
- Offer to go deeper on any sub-concept

Format output:
```
## Step 4: REFINE

[Re-explanation of weak spots if any...]

**TL;DR**: [1-2 sentence summary]

Want to go deeper on any of these?
[list sub-concepts as options via AskUserQuestion]
```

---

## Test Mode (`--test`)

User explains, Claude plays "curious student" to surface gaps.

### Step 1: EXPLAIN

Ask the user to explain the concept in their own words. No hints, no scaffolding.

### Step 2: PROBE

Act as a confused but curious student:
- Ask "but why?" on any claim without justification
- Ask "what do you mean by X?" on any jargon or hand-wavy parts
- Ask "what happens if Y?" for edge cases
- Be genuinely curious, not adversarial

### Step 3: IDENTIFY GAPS

After probing, list specific gaps found:
- Concepts they couldn't explain simply
- Areas where they fell back on jargon
- Edge cases they hadn't considered

Point to resources (docs, code in repo, further reading) for each gap.

### Step 4: RE-EXPLAIN

Ask user to re-explain incorporating the gaps. Confirm understanding or repeat probing on remaining weak spots.

---

## After Completion

Offer: "Want me to `/cortex remember` this understanding for future reference?"
