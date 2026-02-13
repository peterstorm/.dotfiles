# Cortex Plugin Review Fixes — All 25 Issues

## Context
Comprehensive review by 4 agents found 4 runtime crashes, 2 data-loss paths, silent failures, type design gaps, and low-priority cleanup items. All claims verified against actual code. This plan fixes all 25 issues in 4 waves.

---

## Wave 1: Runtime Crashes (Issues #1a-d)

All in `engine/src/cli.ts` — signature mismatches that crash at runtime.

### 1a. `handleIndexCode` (line 425-432)
Passes object `{projectDb, globalDb, proseId, ...}` but `executeIndexCode` expects positional `(argv, sessionId, projectDb, globalDb, apiKey, projectName)`.

**Fix:** Change to positional args:
```ts
const result = await executeIndexCode(
  [proseId, codePath],  // argv
  'manual-index',        // sessionId
  projectDb,
  globalDb,
  getGeminiApiKey(),
  getProjectName(cwd)
);
```
**File:** `engine/src/cli.ts:424-432`

### 1b. `handleConsolidate` (line 540)
`findSimilarPairs(projectDb)` — expects `(memories[], threshold?)` but gets `Database`.

**Fix:** Fetch active memories first, then pass to pure function:
```ts
const memories = getActiveMemories(projectDb);
const pairs = findSimilarPairs(memories);
```
**File:** `engine/src/cli.ts:540`, add import for `getActiveMemories`

### 1c. `handleTraverse` (line 610)
Passes `{ memoryId, maxDepth }` but `TraverseOptions` expects `{ id, depth }`.

**Fix:** `{ id: memoryId, depth: maxDepth }`
**File:** `engine/src/cli.ts:610,613`

### 1d. `handleLifecycle` (line 577)
`.archivedCount` / `.prunedCount` → should be `.archived` / `.pruned`.

**Fix:** Drop `Count` suffix.
**File:** `engine/src/cli.ts:577`

---

## Wave 2: Data Loss & Silent Failures (Issues #2-4, #7-10, #13)

### 2. Checkpoint not saved on Claude failure
**File:** `engine/src/commands/extract.ts:152-162`
Return `newCursor` instead of `cursorStart` on failure. Advances past failed chunk (user choice: no retry).

### 3. `loadCachedSurface` doesn't write `.local.md`
**File:** `engine/src/commands/generate.ts:126-166`
After loading cache, write surface to `.claude/cortex-memory.local.md`.
**Also file:** `engine/src/cli.ts:729` — `handleLoadSurface` should call write after load.
Add `getSurfaceOutputPath` import and `fs.writeFileSync(outputPath, result.surface)`.

### 4. `filterUnembedded` AND logic blocks dual backfill
**File:** `engine/src/commands/backfill.ts:29-32`
Split into two filters:
- `filterGeminiUnembedded`: `m.embedding === null`
- `filterLocalUnembedded`: `m.local_embedding === null`
Backfill function should pick filter based on which method is being used (Gemini or local).

### 7. Recall discards cosine scores
**File:** `engine/src/commands/recall.ts:220-234`
**File:** `engine/src/infra/db.ts` — `searchByEmbedding` return type
Change `searchByEmbedding` to return `{memory, score}[]` instead of `Memory[]`.
Propagate scores to `SearchResult` instead of hardcoding 1.0.
Split cosine computation out of db.ts into caller (also fixes #11 FC/IS violation).

### 8. No keyword fallback on semantic failure
**File:** `engine/src/commands/recall.ts:174-201`
Wrap embedding search in try/catch, fallback to keyword on error. Log the fallback.

### 9. `searchByEmbedding` throws on null embedding
**File:** `engine/src/infra/db.ts:578-582`
Change `throw` to `console.warn` + `continue` (skip corrupt row).

### 10. Local model load failure cached forever
**File:** `engine/src/infra/local-embed.ts:103-111`
Clear `modelAvailabilityCache` on failure so next call retries. Or add TTL (5min cache on failure).

### 13. Parse failure returns empty silently
**File:** `engine/src/core/extraction.ts:198-200`
Add `console.error` / `process.stderr.write` in catch block with truncated response for debugging.
Note: this is a pure function, so logging is a pragmatic exception — alternatively return `Either<Error, MemoryCandidate[]>`.

---

## Wave 3: Important Cleanup (Issues #5-6, #11-12)

### 5. Hardcoded staleness check
**File:** `engine/src/commands/generate.ts:156`
Replace `24` with `SURFACE_STALE_HOURS` from config.ts.

### 6. Dead code `getSurfaceCachePath`
**File:** `engine/src/config.ts:74-79`
Remove function. It's never called (cache uses hash-based keys).

### 11. FC/IS violation in db.ts
**File:** `engine/src/infra/db.ts:17, 570-590`
Addressed as part of #7. `searchByEmbedding` returns raw `{memory, embedding}[]`, caller computes cosine in core/recall or similar.

### 12. Script continues after extract failure
**Keep current behavior** (user decision). Add clarifying comment.

---

## Wave 4: Type Design + Low Priority (Issues #14-25)

### 14. Branded types for IDs
**File:** `engine/src/core/types.ts`
Add:
```ts
type MemoryId = string & { readonly __brand: 'MemoryId' };
type EdgeId = string & { readonly __brand: 'EdgeId' };
const MemoryId = (s: string): MemoryId => s as MemoryId;
```
Update Memory, Edge types. Propagate through db.ts, commands.

### 15. Branded embedding types
**File:** `engine/src/core/types.ts`
```ts
type GeminiEmbedding = Float64Array & { readonly __brand: 'GeminiEmbedding' };
type LocalEmbedding = Float32Array & { readonly __brand: 'LocalEmbedding' };
```

### 16. Tags defensive copy
**File:** `engine/src/core/types.ts:239`
`tags: [...(input.tags ?? [])]`

### 17. Type assertions → type guards in DB
**File:** `engine/src/infra/db.ts:720,743`
Add `isEdgeRelation`, `isMemoryType` guards. Throw on invalid DB data.

### 18. Non-exhaustive matching in surface.ts
**File:** `engine/src/core/surface.ts:114,149`
Replace `budgets[category as MemoryType] ?? 0` with ts-pattern exhaustive match.

### 19. Consolidation checkpoint cleanup
**File:** `engine/src/commands/consolidate.ts:386-400`
Delete checkpoint file on success.

### 20. PID lock TOCTOU
**File:** `engine/src/infra/filesystem.ts:61-87`
Use atomic `mkdir` for lock instead of check-then-create.

### 21. DB connections on uncaught exceptions
**File:** `engine/src/cli.ts:810-815`
Add `process.on('uncaughtException', ...)` to close DBs.

### 22. Surface token budget markdown overhead
**File:** `engine/src/core/surface.ts` / `config.ts`
Reserve ~200 tokens for markdown formatting overhead.

### 23. source_context schema inconsistency
Define shared `SourceContext` type used by extract/remember/index-code.

### 24. Gemini API key inconsistency
**File:** `engine/src/infra/gemini-llm.ts:72`
Switch from URL query param to `x-goog-api-key` header (matches gemini-embed.ts).

### 25. Redundant `computeAllCentrality` calls
Cache centrality scores per pipeline run. Pass precomputed map instead of recomputing.

---

## Verification

After each wave:
1. `bun test` in `engine/` — all existing tests pass
2. Type-check: `bun x tsc --noEmit`
3. Manual: `echo '{"session_id":"test","transcript_path":"/tmp/test","cwd":"/home/peterstorm/.dotfiles"}' | bun engine/src/cli.ts extract` — should not crash
4. Wave 1 specifically: test each fixed CLI subcommand manually
5. Wave 2: verify `/tmp/cortex-extract.log` shows correct behavior on simulated failure
6. Wave 4: `bun x tsc --noEmit` confirms branded types catch misuse at compile time

---

## Unresolved Questions
- #13: pure `parseExtractionResponse` logging via stderr vs returning Either — pragmatic stderr ok?
- #25: centrality caching scope — per-pipeline or persist to DB with TTL?
- #15: branded embeddings require updating all embedding consumers — worth the churn for a plugin?
