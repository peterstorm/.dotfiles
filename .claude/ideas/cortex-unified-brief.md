# Cortex — Unified Brief for Loom

Persistent memory plugin for Claude Code. Captures knowledge from sessions, surfaces context at start, provides semantic recall mid-session. Key differentiator: code-aware memory via prose-code pairing.

## Sources Consolidated

- `.claude/specs/2026-02-06-cortex/spec.md` — 89 FRs, 9 user scenarios, 10 NFRs
- `.claude/plans/2026-02-06-cortex.md` — architecture, file structure, component design, phases
- `.claude/ideas/cortex-decisions.md` — 12 resolved design decisions
- `.claude/ideas/cortex-implementation-plan.md` — original Python-based plan (superseded by TS plan)
- `.claude/ideas/memory-mcp-fork.md` — gap analysis of memory-mcp, memory-palace patterns, Neumann enhancements
- `.claude/specs/2026-02-06-cortex/clarifications/log.md` — 10 resolved clarification markers

---

## Resolved Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Plugin type | Native Claude Code plugin (hooks + skills, no MCP server) |
| 2 | Engine language | TypeScript compiled to JS via bun |
| 3 | Storage | SQLite via better-sqlite3 (WAL, FTS5, BLOB embeddings) |
| 4 | Embeddings | Voyage AI (voyage-3.5-lite, 1024d) primary, @huggingface/transformers all-MiniLM-L6-v2 (384d) fallback |
| 5 | Background LLM | Haiku API (~$0.02-0.05/day) |
| 6 | Interactive LLM | Claude subscription (skills run inside Claude Code) |
| 7 | Push surface | `.claude/cortex-memory.local.md` (auto-loaded, auto-gitignored) |
| 8 | Pull mechanism | Skills (/recall, /remember, /index-code, /forget, /consolidate) |
| 9 | Scope | Dual-DB: `.memory/cortex.db` per project + `~/.claude/memory/cortex-global.db` |
| 10 | Code indexing | Prose-code pairing (prose embedded, code stored raw, linked via `source_of` edge) |
| 11 | Stop hook input | JSON stdin `{ session_id, transcript_path, cwd }`, transcript is JSONL |
| 12 | Global/project classify | LLM suggests at extraction, >0.8 confidence = global, else project |
| 13 | Consolidation thresholds | Two-tier: 0.7 auto, 0.5 manual /consolidate |
| 14 | Centrality | Simple in-degree counting (not PageRank) |
| 15 | Local embedding model | all-MiniLM-L6-v2 (384d) |
| 16 | Push surface budget | Dynamic 300-500 tokens, allow overflow for high-value |
| 17 | Embedding backfill | Background async at next session start |
| 18 | /index-code trigger | Manual-only v1, auto on Write/Edit deferred to v2 |
| 19 | Pinning UI | `--pin` flag on /remember |
| 20 | Supersession | Human-only. LLM forbidden from creating `supersedes` edges. |

---

## Architecture

### Functional Core / Imperative Shell

```
Engine Core (pure, 90%+ unit testable):
  types.ts        — Memory, Edge, Extraction (discriminated unions, ts-pattern)
  ranking.ts      — rank score formula, push surface selection, recall merge
  decay.ts        — confidence decay, half-life map, archive/prune transitions
  graph.ts        — in-degree centrality, similarity classification, edge sanitization + alias normalization
  similarity.ts   — cosine similarity, batch search
  surface.ts      — push surface markdown generation
  extraction.ts   — prompt builder, response parser, transcript truncation

Engine Infra (I/O shell):
  db.ts           — SQLite schema, WAL, CRUD, FTS5, checkpoint/restore
  voyage.ts       — Voyage AI HTTP client (embed)
  haiku.ts        — Haiku API client (extract, classify edges, consolidate)
  local-embeddings.ts — @huggingface/transformers fallback
  git-context.ts  — branch, commits, changed files
  filesystem.ts   — file read/write, .gitignore mgmt

CLI Commands (thin orchestration):
  extract, recall, remember, index-code, forget, consolidate, generate, lifecycle, traverse

Plugin Integration:
  hooks/Stop/extract-and-generate.sh
  skills/ — recall.md, remember.md, index-code.md, forget.md, consolidate.md
  plugin.json
```

### Data Model

**memories**: id, content, summary, memory_type (8 types), category (project/global), voyage_embedding (BLOB), local_embedding (BLOB), confidence (0-1), priority (1-10), pinned, source_type, source_session, source_context, tags (JSON), access_count, last_accessed_at, created_at, updated_at, status (active/superseded/archived/pruned)

**edges**: id, source_id, target_id, relation_type (7 types: relates_to, derived_from, contradicts, exemplifies, refines, supersedes, source_of), strength (0-1), bidirectional, status (active/suggested), created_at. Unique on (source_id, target_id, relation_type).

**extractions**: id, session_id, cursor_position, extracted_at

### Data Flow

```
Session End:
  stdin JSON → read transcript → truncate (pure) → gather git context (I/O)
  → build extraction prompt (pure) → Haiku (I/O) → parse (pure)
  → store memories (I/O) → embed via Voyage (I/O) → compute similarity (pure)
  → Jaccard pre-filter (pure) → create edges (I/O) → classify edge types batch (I/O)
  → compute centrality (pure) → compute decay (pure) → rank (pure)
  → select push surface (pure) → generate markdown (pure) → write file (I/O, with PID lock)
  → apply lifecycle: decay → archive → prune → consolidation trigger

/recall:
  query → embed query with metadata prefix (pure) → Voyage (I/O)
  → cosine similarity (pure) on project+global
  → optional --branch filter (pure) → merge results (pure)
  → follow source_of edges (I/O) → traverse related (I/O, depth 2)
  → top 10 → update access stats (I/O) → stdout

/recall (offline / FTS5 fallback):
  query → FTS5 keyword search (I/O) on project+global
  → rank by: (priority/10 * 0.4) + (centrality * 0.3) + (log(access+1)/max_log * 0.3)
  → (importance replaces similarity when no embeddings available)
  → follow source_of edges → top 10 → stdout

/remember:
  text + flags → create Memory (pure) → insert DB (I/O) → queue embedding
```

### Ranking Formula

```
rank = (confidence * 0.5) + (priority/10 * 0.2) + (centrality * 0.15) + (log(access+1)/max_log * 0.15)
```

### Decay

| Memory Type | Half-life |
|-------------|-----------|
| architecture, decision, code_description, code | Stable (no decay) |
| pattern | 60 days |
| gotcha | 45 days |
| context | 30 days |
| progress | 7 days |

Modifiers: pinned = no decay, access_count >10 = 2x half-life, centrality >0.5 = 2x half-life

### Lifecycle

```
active → (confidence <0.3 for 14d) → archived
  EXCEPT: centrality >0.5 memories exempt from archival (hub protection)
archived → (accessed via /recall) → active (restored)
archived → (30d untouched) → pruned (deleted)
```

### Geometric Conflict Classification (Neumann)

```
similarity < 0.1  → no relation (orthogonal)
similarity 0.1-0.5 → create relates_to edge
similarity 0.4-0.5 → also create suggested edge for user review
similarity > 0.5  → flag for consolidation
```

### Edge Alias Normalization

LLM edge type output normalized before storage: `derives→derived_from`, `contradict→contradicts`, `related→relates_to`, `example→exemplifies`, `refine→refines`, `supersede→supersedes`, `source→source_of`. Prevents silent edge creation failures from LLM string inconsistency. Implemented in `sanitizeEdgeType()`.

---

## Full Feature Inventory

### From Spec (89 FRs) — Already Defined

- Auto-extraction at session end (Stop hook) with cursor tracking
- Push surface generation (.claude/cortex-memory.local.md) between markers
- Semantic search (/recall) with FTS5 offline fallback
- Prose-code pairing (/index-code) — prose embedded, code stored raw, source_of edge
- Explicit memory (/remember with --type, --priority, --global, --pin)
- Typed graph edges (7 types, auto-linking by similarity, batch Haiku classification)
- Consolidation (auto every 10 extractions or >80 active, manual /consolidate, checkpoint/rollback)
- Lifecycle (confidence decay per type, archive at <0.3 for 14d, prune at 30d, restore on access)
- Git context injection (branch, commits, changed files in extraction prompt)
- Dual DB (project `.memory/cortex.db` + global `~/.claude/memory/cortex-global.db`)
- Memory /forget (archive by ID or fuzzy query)

### Gaps from Ideas — To Add

#### Gap 1: Graph Traversal API
**Source:** memory-palace pattern #6 — BFS from start node, depth 5, filter by type/direction/strength
**Why:** Graph is write-only without this. Prose-code pairing needs edge following (FR-036 says follow `source_of` but provides no mechanism). Claude can't discover related memories by traversing edges.
**Add:** `traverse` CLI command. Given memory ID, BFS up to depth N, filter by edge type/direction/min strength. Results grouped by depth. Also add basic `get <id>` command for fetching single memory by ID.

#### Gap 2: Embedding Metadata Injection
**Source:** memory-palace pattern #5 — prefix `[type] [project:X]` before embedding
**Why:** Zero-cost improvement. Memories of different types/projects naturally cluster in vector space. Improves recall precision.
**Add:** In extraction pipeline, prefix embedding text: `[memory_type] [project:name] summary content`. Same prefix on /recall query embeddings for aligned search.

#### Gap 3: Proactive Skill Docstrings
**Source:** memory-palace pattern #8 — engineer descriptions to make Claude use memory reflexively
**Why:** Skills are useless if Claude doesn't invoke them. Prompt engineering at skill-definition level drives adoption.
**Add:** Write skill .md descriptions with proactive language: /recall → "USE AS REFLEX when context might exist", /remember → "STORE without being asked when decisions/patterns emerge in conversation."

#### Gap 4: Session-Adaptive Consciousness
**Source:** Neumann pattern #2, simplified — branch/cwd exact cache for push surface
**Why:** Auth session shouldn't get same surface as UI session. Generic top-N ranking wastes token budget.
**Add:** Cache push surfaces keyed by (branch, cwd). On generation, boost memories tagged with current branch. On session start, serve cached surface if available. Cache invalidation on new extraction.

#### Gap 5: Per-Category Line Budgets
**Source:** memory-mcp "keep" — arch 25, decision 25, pattern 25, gotcha 20, progress 30, context 15, code_desc 10
**Why:** Without caps, one dominant category fills entire surface. Risk of all-progress or all-architecture push surface.
**Add:** Soft per-category caps in surface generator. Redistribution: if one category under-budget, redistribute to others. Total still targets 300-500 tokens.

#### Gap 6: Suggestion-Tier Auto-Linking
**Source:** memory-palace pattern #3 — tiered confidence for edge creation
**Why:** Binary create/don't loses medium-confidence relationships. These could be valuable if user confirms.
**Add:** Similarity 0.4-0.5 creates edge with `status=suggested`. Suggested edges surfaced during /consolidate for user review. Promoted to active or deleted.

#### Gap 7: Jaccard Pre-Filter
**Source:** memory-mcp-fork gap #1 — cheap first pass before expensive embedding similarity
**Why:** For large memory stores, comparing every new memory against all existing via embedding = O(n) Voyage API calls. Jaccard is free.
**Add:** Before embedding similarity: tokenize summary, Jaccard score against existing. >0.6 → definitely similar (skip to consolidation). <0.1 → definitely different (skip embedding). Only compute embedding similarity for 0.1-0.6 "maybe" range.

#### Gap 8: PID-Based File Locking
**Source:** memory-mcp "keep" — atomic writes with PID lock
**Why:** Concurrent sessions could corrupt `.claude/cortex-memory.local.md`. SQLite WAL covers DB but not file writes.
**Add:** PID lockfile at `.memory/cortex.lock`. Check before writing surface file. Stale lock detection (PID no longer running). Release after write.

#### Gap 9: Branch-Specific Memory Querying
**Source:** memory-mcp-fork gap #2 — "Separate branch-specific progress from cross-branch architecture"
**Why:** sourceContext field exists (FR-091) but no query filtering. /recall searches all memories regardless of branch context.
**Add:** /recall supports optional `--branch` flag. Push surface auto-filters context-specific tier by current branch. Progress memories on feature branches deprioritized when on main.

---

## Spec Scope Reconsiderations

Original spec excluded "Advanced graph queries — no BFS traversal" (out of scope). This should be reconsidered: minimal BFS traversal (depth 2-3, filter by edge type) needed to realize prose-code value prop (FR-036). Without it, `source_of` edges are decorative.

---

## Key Technical Findings

- Haiku can't generate embeddings — Voyage AI is Anthropic's embedding partner
- Stop hook receives JSON stdin: `{ session_id, transcript_path, cwd }`. Transcript is JSONL.
- Plugins can't bundle deps — TS→JS + better-sqlite3 native addon works. `bun ${CLAUDE_PLUGIN_ROOT}/engine/dist/cli.js`
- `.claude/*.local.md` files auto-loaded by Claude Code, auto-gitignored
- Subagents bypass PreToolUse hooks (by design)
- In-degree centrality sufficient for <1000 memories

---

## Cost Model

10 sessions/day, 5k tokens avg transcript:

| Operation | Per-session | Daily (10) |
|-----------|------------|------------|
| Haiku extraction | ~$0.001 | $0.01 |
| Haiku edge classification | ~$0.001 | $0.01 |
| Voyage embeddings | ~$0.0005/memory | ~$0.01 |
| Haiku consolidation | ~$0.01/batch | ~$0.01 (not every session) |
| **Total** | | **~$0.03-0.05/day** |

Voyage free tier: 200M tokens/month. At ~500 tokens/memory, ~50 memories/day = 25k tokens/day = 750k/month. Well within.

---

## NFRs Summary

- Extraction <30s (p95), Surface gen <5s, /recall <2s
- Handle 10,000+ memories
- Offline: FTS5 fallback, queue embeddings/extraction
- Cost <$0.15/day
- WAL + PID locking for concurrent safety
- Checkpoint before destructive ops
- Errors to `.memory/cortex.log`, never disrupt session
- Code content never sent to embedding API
- API keys from env vars only

---

## Testing Strategy

| Layer | Approach |
|-------|----------|
| Domain (pure) | Unit + property tests (ranking invariants, decay monotonicity, similarity symmetry, centrality bounds, Jaccard correctness) |
| Infra (I/O) | Integration tests (in-memory SQLite, mocked HTTP) |
| Commands | End-to-end with in-memory DB |
| Surface | Snapshot tests for markdown output |
| Graph traversal | Unit tests with known edge sets, depth limits |

Target: 90%+ domain code unit testable without mocks.

---

## Dependencies

- Claude Code plugin system (hooks, skills, agents)
- Voyage AI API (voyage-3.5-lite)
- Anthropic API (Haiku)
- @huggingface/transformers (bun compat?)
- better-sqlite3 (bun native addon, darwin arm64?)
- bun runtime
- SQLite FTS5

---

## v2 / Deferred Ideas

Items explicitly deferred from v1, captured to prevent loss:

- **Auto /index-code on Write/Edit** — FR-046 defers to v2. Auto-trigger code re-indexing when files are modified via tools.
- **Batch code indexing** — recursive `/index-code src/` on entire directories
- **Memory export/import** — markdown export, bulk import from other projects
- **Cross-instance handoff** — async message-passing between Claude Desktop, Code, and Web instances (memory-palace pattern)
- **Real-time mid-session extraction** — extract memories during session, not just at end
- **Hot/cold explicit memory tiers** — explicit tiering vs current implicit centrality-weighted ranking (Neumann, simplified away for v1)
- **Configurable ranking weights** — ranking formula weights adjustable via env vars, auto-normalized to sum to 1.0
- **Edge strength decay** — weak edges between old memories fade over time, prevents graph "hairball" (spec risk table)
- **Edge metadata JSON field** — arbitrary context per edge (memory-palace stores edge_metadata per edge)

## clnode Integration Path

Cortex v1 extracts from raw conversation transcripts. If clnode patterns (intra-session agent communication) are implemented, loom agent **structured work summaries** become a richer extraction source:

```
Agent completes → SubagentStop: compress → work_summary (clnode)
→ SessionEnd: extract from summaries → cortex memory store
→ Next session: inject relevant memories (cortex)
```

Not blocking for v1 — cortex works standalone. But extraction pipeline should be designed to accept structured input (work summaries) in addition to raw transcripts, so clnode integration is additive.

---

## Open Questions

1. `@huggingface/transformers` bun compat — WASM backend needed?
2. better-sqlite3 bun native addon — builds on darwin arm64?
3. plugin.json schema — exact Claude Code manifest format?
4. Voyage API batch limits — max texts per request?
5. Stop hook — verify actual payload shape
6. Graph traversal depth — 2-3 for v1?
7. Suggested edges — separate table or status field on edges?
8. Per-category line budgets — exact allocation or soft caps w/ redistribution?
9. Embedding metadata prefix — does `[type] [project:X]` improve Voyage clustering?
