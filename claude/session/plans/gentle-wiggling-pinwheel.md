# Fix All Remaining Cortex Plugin Issues

## Context

Review at `.claude/reviews/2026-02-12-cortex-plugin-review.md` identified 25 issues. ~13 already fixed. 9 remain — test infra, type safety, FC/IS boundary violation, keyword scoring, parse logging, shell script. This plan fixes all 9.

---

## Wave 1: Test Infra (unblocks validation)

### 1a. Remove `bun:test` imports (6 files)

vitest.config.ts has `globals: true` — all test functions globally available. Delete the import line from each:

| File | Line |
|------|------|
| `src/commands/inspect.test.ts` | 6 |
| `src/commands/consolidate.test.ts` | 6 |
| `src/commands/lifecycle.test.ts` | 6 |
| `src/commands/generate.test.ts` | 1 |
| `src/commands/index-code.test.ts` | 7 |
| `src/commands/recall.test.ts` | 6 |

### 1b. Fix `recall.test.ts` spyOn

After removing `bun:test` import, `spyOn` gone. Change to `vi.spyOn` (vitest global):
- Line 58: `spyOn(...)` → `vi.spyOn(...)`
- Line 63: `spyOn(...)` → `vi.spyOn(...)`

### 1c. Fix `toEndWith` in `extraction.test.ts:729`

Not a vitest matcher. Replace:
```typescript
// before
expect(result).toEndWith(memory.summary);
// after
expect(result.endsWith(memory.summary)).toBe(true);
```

**Verify:** `bun x vitest run` → 587/587 pass

---

## Wave 2: Pure Core Fixes

### 2a. Type guards in `extraction.ts:186-197`

Replace `as MemoryType` / `as MemoryScope` casts with narrowing via `isMemoryType` guard (already exported from types.ts). Add import, then:

```typescript
// isValidCandidate already validates, but make type-safe without casts
.filter(isValidCandidate)
.map((c) => {
  const memory_type = isMemoryType(c.memory_type) ? c.memory_type : 'context';
  const scope: MemoryScope = c.scope === 'global' ? 'global' : 'project';
  return { content: String(c.content), summary: String(c.summary), memory_type, scope, ... };
})
```

Files: `engine/src/core/extraction.ts`

### 2b. Type guards in `surface.ts:114, 131, 149`

Replace `budgets[category as MemoryType] ?? 0` with guard:

```typescript
for (const [category, mems] of Object.entries(byCategory)) {
  if (!isMemoryType(category)) continue;
  const budget = budgets[category] ?? 0;
```

Apply at 3 locations (first pass L114, unused calc L131, overflow L149). Add `isMemoryType` value import.

Files: `engine/src/core/surface.ts`

### 2c. Parse warnings in `extraction.ts:180-197`

Add stderr warnings for silent empty results:

1. L182: when parsed is not array → log type before returning `[]`
2. After filter: when all candidates filtered out → log `"0 valid from N raw"`

Restructure: separate `.filter()` from `.map()` to insert the warning between.

Files: `engine/src/core/extraction.ts`

---

## Wave 3: I/O Layer + Shell

### 3a. FC/IS refactor — split `searchByEmbedding`

**Problem:** `db.ts:17` imports `cosineSimilarity` from `core/similarity.ts`. Infra shouldn't do pure computation.

**Step 1:** Add to `core/similarity.ts`:
```typescript
export function rankBySimilarity(
  candidates: readonly { memory: Memory; embedding: Float64Array | Float32Array }[],
  queryEmbedding: Float64Array | Float32Array,
  limit: number
): readonly { memory: Memory; score: number }[] {
  return candidates
    .map(({ memory, embedding }) => ({ memory, score: cosineSimilarity(queryEmbedding, embedding) }))
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
```

**Step 2:** Replace `searchByEmbedding` in `db.ts` with fetch-only:
```typescript
export function getMemoriesWithEmbedding(
  db: Database, type: 'gemini' | 'local'
): readonly { memory: Memory; embedding: Float64Array | Float32Array }[] { ... }
```
Remove `cosineSimilarity` import from db.ts.

**Step 3:** Update `recall.ts` to use split functions:
```typescript
import { getMemoriesWithEmbedding } from '../infra/db.js';
import { rankBySimilarity } from '../core/similarity.js';

const embType = queryEmbedding instanceof Float64Array ? 'gemini' : 'local';
const projectCandidates = getMemoriesWithEmbedding(projectDb, embType);
const projectEmbedResults = rankBySimilarity(projectCandidates, queryEmbedding, limit);
```

Keep `EmbeddingSearchResult` type alias for backwards compat or remove (only recall.ts imports it).

Files: `engine/src/infra/db.ts`, `engine/src/core/similarity.ts`, `engine/src/commands/recall.ts`

### 3b. Keyword search position scoring in `recall.ts`

FTS5 returns results ordered by rank but scores aren't propagated. Add helper:

```typescript
function assignPositionScores(memories: readonly Memory[], source: 'project' | 'global'): SearchResult[] {
  return memories.map((memory, i) => ({
    memory,
    score: memories.length > 1 ? 1 - (i / (memories.length - 1)) * 0.5 : 1.0,
    source, related: [],
  }));
}
```

Replace all 4 keyword mapping locations (semantic fallback L216-221, L219-221, primary keyword L234-238).

Score range: [1.0 → 0.5] preserves FTS5 ordering through `mergeResults` sort.

Files: `engine/src/commands/recall.ts`

### 3c. Shell script — skip backfill on extract failure

```bash
local extract_ok=true
if ! echo "$stdin_json" | bun "$CLI_PATH" extract ...; then
  log_error "Extract failed"
  extract_ok=false
fi

# Only backfill if extraction succeeded
if [[ "$extract_ok" == true ]] && [[ -n "$cwd" ]]; then
  ...backfill...
fi

# Always generate (stale memories still need fresh surface)
```

Files: `hooks/scripts/extract-and-generate.sh`

---

## Wave 4: Cleanup

### 4a. Update review doc

Mark all fixed issues with `[FIXED]` in `.claude/reviews/2026-02-12-cortex-plugin-review.md`. Update metrics table.

### 4b. Full test suite

```bash
cd .claude/plugins/cortex/engine && bun x vitest run
```

All tests green.

---

## Decisions Made

| Question | Decision | Rationale |
|----------|----------|-----------|
| Keep `searchByEmbedding` wrapper? | Remove entirely | Only recall.ts uses it; clean FC/IS split is the goal |
| `rankBySimilarity` location? | `similarity.ts` | Uses `cosineSimilarity`; ranking.ts is for surface ranking (different concern) |
| Keyword score floor? | 0.5 | Semantic cosine scores range 0.3-0.9; keyword 0.5-1.0 interleaves naturally |
| consolidate CLI handler? | Leave as-is | `findSimilarPairs(memories)` is correct pure call; CLI does its own I/O |

## Verification

1. `bun x vitest run` — all tests pass
2. `bun engine/src/cli.ts recall "test query" <cwd>` — verify keyword fallback returns non-uniform scores
3. `bun engine/src/cli.ts extract < test-input.json` — verify parse warning on empty extraction
4. Grep: `rg "from 'bun:test'" src/` — 0 matches
5. Grep: `rg "cosineSimilarity" src/infra/` — 0 matches (removed from infra)
