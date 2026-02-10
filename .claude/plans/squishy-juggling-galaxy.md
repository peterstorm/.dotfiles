# Switch Cortex from Voyage AI + Haiku to Gemini Models

## Context
Cortex currently uses Voyage AI for embeddings (1024d) and Claude Haiku for LLM extraction. Both require paid API keys. Google offers `gemini-embedding-001` (768d) and Gemini 2.5 Flash completely free via Google AI Studio API. No existing DB data — clean slate.

## Changes

### 1. Core type rename
**`src/core/types.ts`** — `voyage_embedding` field → `embedding` (plus all test files referencing it: `types.test.ts`, `decay.test.ts`, `surface.test.ts`, `ranking.test.ts`)

### 2. DB schema + CRUD rename
**`src/infra/db.ts`** — column `voyage_embedding` → `embedding`, update all CRUD functions and variable names (`isVoyage` → `isFloat64` etc.)
**`src/infra/db.test.ts`** — update references

### 3. New Gemini embedding client
**Create `src/infra/gemini-embed.ts`** — replace `voyage.ts`
- `EMBEDDING_DIMENSIONS = 768`
- `MAX_BATCH_SIZE = 100`
- Same exports: `embedTexts()`, `isGeminiAvailable()`, `EMBEDDING_DIMENSIONS`, `MAX_BATCH_SIZE`
- Auth: `x-goog-api-key` header
- Single: `POST .../gemini-embedding-001:embedContent` with `{ content: { parts: [{ text }] }, outputDimensionality: 768 }`
- Batch: `POST .../gemini-embedding-001:batchEmbedContents` with `{ requests: [...] }`
- Response: `{ embedding: { values: [...] } }` → `Float64Array`

**Create `src/infra/gemini-embed.test.ts`** — mirror voyage.test.ts structure, 768d
**Delete** `voyage.ts` + `voyage.test.ts`

### 4. New Gemini LLM client
**Create `src/infra/gemini-llm.ts`** — replace `haiku.ts`
- Same exports: `extractMemories()`, `classifyEdges()`, `isGeminiLlmAvailable()`
- Same types: `MemoryPair`, `EdgeClassification`
- Same pure functions: `buildEdgeClassificationPrompt()`, `parseEdgeClassificationResponse()`
- Auth: `x-goog-api-key` header, raw `fetch` (no SDK)
- Endpoint: `POST .../gemini-2.5-flash:generateContent`
- Body: `{ contents: [{ role: "user", parts: [{ text }] }], generationConfig: { temperature: 0 } }`
- Extract: `response.candidates[0].content.parts[0].text`

**Create `src/infra/gemini-llm.test.ts`** — mirror haiku.test.ts
**Delete** `haiku.ts` + `haiku.test.ts`

### 5. Command file updates (import swaps + field renames)
| File | Changes |
|------|---------|
| `extract.ts` | haiku → gemini-llm imports, `ANTHROPIC_API_KEY` → `GEMINI_API_KEY` msgs |
| `recall.ts` | voyage → gemini-embed, `voyageApiKey` → `geminiApiKey` |
| `index-code.ts` | voyage → gemini-embed, field rename |
| `backfill.ts` | voyage → gemini-embed, `backfillVoyage` → `backfillGemini`, `'voyage'` → `'gemini'` |
| `consolidate.ts` | `voyage_embedding` → `embedding` refs |
| `remember.ts` | `voyage_embedding` → `embedding` |
| `inspect.ts` | `voyage_embedding` → `embedding` |

### 6. Test file updates
All command test files: update mocks, imports, field names, 1024 → 768 dims

### 7. Package cleanup
**`package.json`** — remove `@anthropic-ai/sdk` dependency

## Execution order
1 → 2 → 3 → 4 → 5 → 6 → 7 → `bun test`

## Verification
```bash
cd .claude/plugins/cortex/engine && bun test
```
All ~650 tests should pass (minus pre-existing decay.test.ts NaN issue).

## Unresolved questions
- Standardize import extensions to `.js` everywhere? (currently mixed `.ts`/`.js`)
