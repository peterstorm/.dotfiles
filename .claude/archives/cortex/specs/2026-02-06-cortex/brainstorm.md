# Brainstorm Summary

**Building:** Cortex — a persistent memory plugin for Claude Code that learns from past sessions and surfaces relevant context automatically. Differentiator is code-aware memory with prose-code pairing: when you remember "use Zustand for state," it links to the actual OrderService.ts file where you established that pattern.

**Approach:** Code-aware hybrid (Phase 1 + 2: extraction, storage, skills, code indexing). TypeScript engine integrating with existing loom infrastructure. Push-pull hybrid: auto-surfaces critical memories via `.claude/cortex-memory.local.md` (tiered format), queryable mid-session via `/recall` and `/remember` skills. Graph-backed storage with typed relationships between memories.

**Key Constraints:**
- Cross-session only (no intra-session agent communication — that's clnode's domain)
- Token budget: push surface limited to critical memories (~300-500 tokens), rest queryable on-demand
- Offline-capable: must degrade gracefully when Voyage API unavailable
- TS-native: no Python dependencies, matches existing `.claude/hooks/ts-utils/` infrastructure
- Dual embedding sources: Voyage AI (1024d) primary, @huggingface/transformers (384d) fallback, separate BLOB columns

**In Scope:**
- SessionStop hook: extract memories via Haiku, store in SQLite with embeddings
- Weighted ranking: `(confidence * 0.5) + (priority * 0.2) + (centrality * 0.15) + (access_count * 0.15)`
- Push surface: `.claude/cortex-memory.local.md` with tiered display (critical/context-specific/code-index)
- Skills: `/recall` (semantic search), `/remember` (manual memory), `/index-code` (prose-code pairing), `/forget`, `/consolidate`
- Graph edges: typed relationships (relates_to, derived_from, contradicts, exemplifies, refines, supersedes, source_of)
- Auto-linking: Haiku analyzes new memories for relationships with existing ones
- Code indexing: pair prose descriptions with file paths/line ranges
- Both project + global scope from v1

**Out of Scope:**
- Intra-session agent communication (SubagentStop summaries, work context injection)
- Web UI / dashboard (push surface + skills sufficient)
- Multi-user collaboration (single-user focus)
- Version control integration beyond file path tracking
- Automatic memory consolidation (manual `/consolidate` only for v1)

**Open Questions:**
- Max token budget for push surface critical section (hard limit or dynamic based on session context)?
- Embedding backfill strategy: background job on next online session or lazy on-demand during `/recall`?
- Graph centrality calculation: PageRank-style or simpler in-degree/out-degree scoring?
- Should `/index-code` auto-trigger on Write/Edit tool calls or manual-only for v1?
