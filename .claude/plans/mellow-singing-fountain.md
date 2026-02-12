# Refactor Cortex: Replace Gemini extraction with Claude CLI

## Context

Cortex uses Gemini 2.0 Flash for memory extraction from session transcripts (the expensive LLM call). User wants to leverage their Anthropic subscription via `claude -p` instead, eliminating the Gemini LLM dependency for extraction. Gemini embedding API stays for semantic search (cheap, no good Claude alternative).

## Approach

Replace `extractMemories()` in the infra layer with a new `claude-llm.ts` module that shells out to `claude -p` via `Bun.spawn`. The pure core (prompt building, response parsing) stays untouched. Only the I/O boundary changes.

## Files to modify

### 1. NEW: `engine/src/infra/claude-llm.ts`
- `isClaudeLlmAvailable()` — check `claude` binary exists on PATH (via `Bun.which('claude')`)
- `extractMemories(prompt: string): Promise<string>` — spawn `claude -p <prompt> --output-format text --allowedTools ""`, return stdout text
- Same interface as gemini-llm's `extractMemories` minus the apiKey param
- Error handling: binary not found, non-zero exit, timeout (30s per FR-009)
- `classifyEdges()` — same pattern (not wired in v1, but keep parity)

### 2. MODIFY: `engine/src/commands/extract.ts`
- Import from `claude-llm.ts` instead of `gemini-llm.ts`
- Remove `apiKey` parameter from `executeExtract()` signature
- Use `isClaudeLlmAvailable()` check instead of `isGeminiLlmAvailable(apiKey)`
- Update log messages: "Using Claude for memory extraction"

### 3. MODIFY: `engine/src/cli.ts`
- `handleExtract()`: remove `getGeminiApiKey()` call, don't pass apiKey to `executeExtract`
- Rest of CLI stays the same (backfill/recall still use Gemini for embeddings)

### 4. MODIFY: `engine/src/config.ts`
- Add `isClaudeAvailable(): boolean` — checks `Bun.which('claude') !== null`
- Keep `getGeminiApiKey()` (still used by backfill/recall for embeddings)

### 5. MODIFY: `hooks/scripts/extract-and-generate.sh`
- Keep GEMINI_API_KEY sourcing (still needed for backfill step)
- No functional change needed (extraction no longer needs the key, but backfill does)

### 6. MODIFY: `HOW-IT-WORKS.md`
- Update "30-second version" and section 4 (Gemini LLM Calls) to reflect Claude extraction
- Note that embeddings still use Gemini

## Key decisions

- **Prompt via argument**: ~100KB max. Linux ARG_MAX is ~2MB. Safe.
- **`--allowedTools ""`**: Extraction is pure text→JSON, no tools needed
- **`--output-format text`**: Returns raw assistant text (the JSON array we parse)
- **No model flag**: Uses whatever the user's subscription defaults to
- **Timeout**: 30s via Bun.spawn timeout option (matches existing FR-009)
- **Keep gemini-llm.ts**: Don't delete — `classifyEdges` might be wired later, and it serves as reference. Just stop importing `extractMemories` from it.

## What stays the same

- `core/extraction.ts` (prompt builder, response parser) — untouched
- `infra/gemini-embed.ts` (embeddings) — untouched
- `commands/backfill.ts` — still uses Gemini for embeddings
- `commands/recall.ts` — still uses Gemini for semantic search
- All pure functions, similarity, ranking, surface generation — untouched

## Verification

1. `git add . && bun run engine/src/cli.ts extract` with a test transcript piped in — confirm Claude extracts memories
2. Check `/tmp/cortex-extract.log` for "Using Claude for memory extraction"
3. Verify backfill still works with Gemini embeddings: `bun run engine/src/cli.ts backfill <cwd>`
4. Verify recall still works: `bun run engine/src/cli.ts recall <cwd> "test query"`

## Unresolved

- `claude -p` reads prompt as positional arg or stdin? Need to verify. Fallback: write prompt to tmp file, pipe via stdin.
- Will `claude` binary be on PATH inside hook bash context? Should be since hook is child of Claude Code. Add fallback PATH check.
