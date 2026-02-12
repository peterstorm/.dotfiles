# Plan: Recency Decay + Token Budget Increase for Cortex Surfacing

## Context
No new memories have surfaced for days. Root cause: ranking formula has **zero recency signal** — early high-confidence memories permanently dominate. Compounding factor: token budget is only 400-550 tokens (~6 memories), so even slight ranking advantages lock others out.

## Changes

### 1. Add recency multiplier to `computeRank` — `ranking.ts`

Add multiplicative recency factor after computing base rank:

```
recencyMultiplier = 1 / (1 + ageDays / RECENCY_HALF_LIFE_DAYS)
rank = baseRank * recencyMultiplier
```

With `RECENCY_HALF_LIFE_DAYS = 14`:
- 0 days → ×1.0, 7 days → ×0.67, 14 days → ×0.5, 30 days → ×0.31

**Pinned memories exempt** (multiplier = 1.0).

Multiplicative chosen over additive because it preserves relative quality ordering — a new low-quality memory can't outrank an old excellent one by recency alone.

New option in `computeRank`: `recencyHalfLifeDays?: number` (default 14), `now?: Date` (for testability).

**Files:**
- `engine/src/core/ranking.ts` — add recency to `computeRank`
- `engine/src/core/ranking.test.ts` — add recency tests + update existing expected values
- `engine/src/config.ts` — add `RECENCY_HALF_LIFE_DAYS = 14`

### 2. Increase token budget — `generate.ts` + `config.ts` + `surface.ts`

| Setting | Old | New |
|---|---|---|
| `targetTokens` (generate.ts) | 400 | 1500 |
| `maxTokens` (generate.ts) | 550 | 2000 |
| `SURFACE_MAX_TOKENS` (config.ts) | 600 | 2000 |
| `maxTokens` default (surface.ts) | 1000 | 2000 |
| `selectForSurface` defaults (ranking.ts) | 800/1000 | 1500/2000 |

**Files:**
- `engine/src/commands/generate.ts:86-87` — update targetTokens/maxTokens
- `engine/src/config.ts:151` — update SURFACE_MAX_TOKENS
- `engine/src/core/surface.ts:42` — update default maxTokens
- `engine/src/core/ranking.ts:56` — update default targetTokens/maxTokens
- `engine/src/core/surface.test.ts` — update token expectations in tests

## Verification

```bash
cd .claude/plugins/cortex/engine
bun test src/core/ranking.test.ts
bun test src/core/surface.test.ts
bun test src/commands/generate.test.ts
```

Then regenerate surface to confirm new memories appear:
```bash
bun engine/src/cli.ts generate
cat .claude/cortex-memory.local.md
```

## Unresolved Questions
- half-life 14 days aggressive enough? could do 7 for faster turnover
- should stable types (architecture, decision) have longer recency half-life? or keep uniform for simplicity
