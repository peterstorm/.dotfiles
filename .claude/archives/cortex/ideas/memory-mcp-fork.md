# memory-mcp Fork Ideas

Based on research of the memory MCP landscape and deep analysis of [yuvalsuede/memory-mcp](https://github.com/yuvalsuede/memory-mcp).

## Landscape Summary

Evaluated 7+ memory MCP solutions. `memory-mcp` (yuvalsuede) is the strongest foundation:
- Two-tier memory (CLAUDE.md ~150 lines + full state.json) — best token efficiency
- Silent hook-based extraction (Stop, PreCompact, SessionEnd)
- Jaccard dedup + LLM consolidation via Haiku (~$0.001/extraction)
- 6 memory categories: architecture, decision, pattern, gotcha, progress, context
- Confidence decay: progress 7d, context 30d, arch/decision stable
- Line-budgeted consciousness generation with redistribution

Other solutions evaluated:
- `@modelcontextprotocol/server-memory` (official) — knowledge graph but dumps everything, no token mgmt
- `mcp-memory-keeper` — SQLite + WAL, SHA-256 file hashing, configurable token limits, no semantic dedup
- `claude-memory-mcp` (WhenMoon) — SQLite + FTS5, token budgeting, hybrid relevance scoring, no dedup
- `mcp-memory-service` (doobidoo) — ONNX embeddings, claims 88% token reduction, over-engineered
- `claude-code-memory` — Neo4j graph DB, too heavy
- `memory-palace` (jeffpierce) — SQLite + Ollama local embeddings, knowledge graph with 6 typed edges, prose-code pairing, cross-instance handoff, centrality-weighted retrieval. Query-driven (MCP tools only, no consciousness surface). Strong graph model but no push-based CLAUDE.md equivalent. See [analysis below](#memory-palace-analysis)

## What's Good in memory-mcp (Keep)

- Two-tier architecture (CLAUDE.md compact surface + state.json full store)
- Hook-based silent capture — zero friction
- Memory lifecycle: Created -> Active -> Superseded/Archived -> Decayed (<0.3) -> Pruned (14d)
- Two dedup thresholds: 0.5 explicit supersedes, 0.6 auto-dedup, with stop word removal
- Consolidation triggers: every 10 extractions, >80 active, or SessionEnd
- Line budget: arch/decision/pattern ~25ea, gotcha ~20, progress ~30, context ~15
- Cost model: ~$0.05-0.10/day active dev
- Atomic writes + PID-based locking
- Cursor-based transcript tracking (only processes new content)

## Genuine Gaps (Improvement Opportunities)

### 1. Semantic Dedup is Weak (HIGH IMPACT)

Jaccard on word tokens can't catch paraphrases. "Auth uses JWT tokens" vs "JWT-based authentication" scores low despite being identical semantically. Options:
- **Lightweight embeddings** — use Haiku to generate a short semantic fingerprint during extraction, compare cosine similarity. Adds ~$0.0005/memory but catches real duplicates.
- **LLM-based dedup at consolidation time** — already sends memories to Haiku for merge/drop, could explicitly ask "are any of these saying the same thing?"
- **Hybrid** — keep Jaccard as cheap first pass, escalate near-misses (0.3-0.6 range) to LLM check

### 2. No Git/Codebase Awareness (HIGH IMPACT)

Extractor reads conversation transcripts only. Blind to:
- Current branch name (could auto-tag memories with branch)
- Recent commits (architectural changes visible in `git log --oneline -10`)
- Files changed (`git diff --stat` reveals what areas are active)
- Branch context (feature branch memories vs main branch memories)

Improvement: Before extraction, gather git context and include in the Haiku prompt. Auto-tag memories with branch. Separate branch-specific progress from cross-branch architecture.

### 3. No Memory Pinning/Priority (MEDIUM)

All memories are equal weight. Can't:
- Pin critical decisions as permanent (never consolidate away)
- Downvote/remove bad memories easily
- Mark memories as "always surface in CLAUDE.md"

Improvement: Add `pinned: boolean` and `priority: number` fields. Pinned memories skip decay and consolidation. Priority influences consciousness generation ranking.

### 4. Static Consciousness Surface (MEDIUM)

CLAUDE.md is the same regardless of session context. Auth-focused session gets same memory surface as UI session.

Options:
- **Session-adaptive rendering** — on SessionStart hook, look at the first user message or working directory to weight relevant categories higher
- **Topic detection** — cluster memories by topic, boost topics matching current work
- **Lazy loading** — keep CLAUDE.md minimal (project overview + top 5 decisions), let Claude pull more via MCP tools as needed

### 5. No Memory Relationships (LOW-MEDIUM)

Memories are flat. "We chose Zustand" doesn't link to "Components use useStore hook." Only connected via shared tags (manual).

Options:
- **Auto-link at extraction** — when Haiku extracts, ask it to reference related memory IDs
- **Tag-based implicit graph** — already exists partially, could be made more explicit
- **Skip it** — flat list with good search may be sufficient. Knowledge graphs add complexity for unclear value in this context.

### 6. No Code Memory (HIGH IMPACT)

All memories are text blobs extracted from conversations. No concept of indexing actual code files. Learned from memory-palace's prose-code pairing:
- Code embeds poorly for natural language queries
- LLM-transpile code → prose description, embed the prose, store raw code separately
- Graph edge (`source_of`) connects prose to code
- "how does auth work?" matches prose, follows edge to actual implementation

This is the biggest missing capability for a developer-facing memory system.

### 7. Push-Only Architecture — No Mid-Session Retrieval (HIGH IMPACT)

System is 100% push (CLAUDE.md at session start). No MCP tools for Claude to query memories mid-conversation. Need a `recall` tool for on-demand retrieval. This also solves the static consciousness problem — keep CLAUDE.md small/generic, let Claude pull context-specific memories via tool calls.

Minimum MCP tool surface needed:
- `memory_recall` — semantic search against memory store
- `memory_remember` — explicit save (not just hook extraction)
- `memory_forget` — archive/remove
- `memory_get` — fetch by ID (for graph traversal follow-up)

### 8. No Retrieval Ranking Model (MEDIUM)

No model for how memories are ranked within each category for consciousness generation. memory-palace uses tri-factor scoring:
```
score = (similarity * 0.7) + (log(access_count + 1) / max_log * 0.15) + (centrality * 0.15)
```
- Graph centrality: hub memories (many incoming edges) rank higher
- Log-transformed access count: prevents popular memories from dominating forever
- Configurable weights

### 9. Supersession Safety (MEDIUM)

Current plan allows LLM-driven supersession. Dangerous — LLM can destroy important memories if it misjudges similarity. memory-palace explicitly forbids LLM from outputting "supersedes" (redirected to "contradicts"). `memory_supersede` is marked "HUMAN-ONLY ACTION."

Recommendation: LLM can merge/consolidate content but never auto-supersede. Supersession requires explicit user action.

### 10. No Provenance Tracking (MEDIUM)

No record of where a memory came from. Need:
- `source_type`: conversation, explicit, inferred, code_index
- `source_session_id`: which session created it
- `source_context`: file path, branch, etc.

Enables: trust scoring (explicit > inferred), debugging bad memories, differentiated decay (inferred decays faster).

### 11. No Access Tracking (LOW-MEDIUM)

No usage signal. A memory retrieved 50 times should resist decay even if old. Track `last_accessed_at` + `access_count`, use log-transform in ranking.

### 12. Edge Vocabulary Underspecified (LOW-MEDIUM)

Only `related_to` and `supersedes` mentioned. memory-palace's 6-type vocabulary is well-designed:

| Edge | Semantics | Direction |
|------|-----------|-----------|
| `relates_to` | General association | Bidirectional |
| `derived_from` | Built from another | Directional |
| `contradicts` | In tension | Bidirectional |
| `exemplifies` | Specific instance | Directional |
| `refines` | More precise version | Directional |
| `supersedes` | Replacement | Directional |

Plus `strength` (0-1) and `bidirectional` flag per edge.

### 13. Error Handling Fully Silent (LOW)

Every catch block swallows errors. Good for not disrupting Claude, bad for debugging.

Improvement: Write errors to `.memory/errors.log` with timestamps. Still silent to Claude, but debuggable. Add `memory-mcp status` to surface recent errors.

## Architecture Decision: Fork vs Build From Scratch

**Recommendation: Fork.**

The core architecture (two-tier, hooks, lifecycle, consolidation) is the hard part and it's done well. The improvements are additive — better dedup, git awareness, pinning — not architectural rewrites.

Fork strategy:
1. Fork yuvalsuede/memory-mcp
2. Add MCP tool surface (recall, remember, forget, get) — push+pull hybrid
3. Add prose-code pairing for code memory
4. Add git context injection to extractor
5. Improve dedup with hybrid Jaccard + LLM escalation
6. Add typed edge vocabulary (6 types + strength + direction)
7. Add centrality-weighted retrieval ranking
8. Add pinning/priority + supersession safety (human-only)
9. Add provenance + access tracking
10. Add error logging
11. Optional: session-adaptive consciousness

## Unresolved Questions

- Embeddings vs LLM-based semantic dedup? Embeddings faster but add dependency. LLM dedup during consolidation simpler.
- How much git context to inject? `git log --oneline -5` + `git diff --stat` + branch name seems right.
- Per-project or global store? Current is per-project. Cross-project could be valuable but complex.
- Consciousness adapt per-session or stay static? Adaptive smarter but harder to debug.
- `memory_pin` MCP tool or just `pinned` field on `memory_save`?
- Three-tier geometric dedup vs hybrid Jaccard+LLM — which cheaper/better?
- Graph edges: in state.json or separate file?
- Hot/cold: surface cold via MCP tool or include IDs in CLAUDE.md for on-demand fetch?
- Checkpoint storage: version suffix or separate dir?
- MCP tool surface: minimal (recall/remember/forget) or full (+ graph tools, code indexing)?
- Code indexing: Haiku for prose transpilation? or skip code memory entirely?
- Supersession: human-only or allow LLM with high threshold (>0.9)?
- Auto-linked edges visible to Claude or just influence ranking silently?
- Access tracking: at consciousness-generation time, MCP recall time, or both?
- Local embedding model as option or Haiku-only?
- Proactive tool docstrings: how aggressive? "USE AS REFLEX" vs subtle hints?

---

## memory-palace Analysis

Deep analysis of [jeffpierce/memory-palace](https://github.com/jeffpierce/memory-palace) — Python/SQLite + Ollama local embeddings, knowledge graph, prose-code pairing.

### Architecture Overview

- **Query-driven** (MCP tools only) vs memory-mcp's push-driven (CLAUDE.md). No consciousness surface.
- **SQLite + optional pgvector** — SQLAlchemy ORM, dual-backend via helper functions. JSON-serialized embeddings on SQLite, native vectors on Postgres.
- **3 tables**: `memories` (content + embedding + lifecycle), `memory_edges` (typed graph), `handoff_messages` (cross-instance messaging)
- **3 LLM roles**: embedding model (nomic-embed-text 768d), generation model (qwen3:14b), classification model (qwen3:1.7b) — all via Ollama
- **Aggressive VRAM mgmt**: `keep_alive: "0"` unloads models after each call, enabling model swapping on consumer GPUs

### Patterns Worth Stealing

#### 1. Prose-Code Pairing (HIGH — biggest unique value)

Code files indexed as two linked memories:
1. **Prose description** (`code_description` type) — LLM-generated summary, embedded for semantic search
2. **Raw code** (`code` type) — stored but deliberately NOT embedded
3. Connected by `source_of` graph edge

Why: code embeds poorly for NL queries. Prose acts as a semantic index. "how does auth work?" matches prose → follows edge → retrieves actual implementation.

Re-indexing uses `force=True` with supersession of old prose+code pair.

#### 2. Centrality-Weighted Retrieval Ranking (HIGH)

Tri-factor scoring:
```
score = (similarity * 0.7) + (log(access_count + 1) / max_log * 0.15) + (centrality * 0.15)
```
- In-degree centrality: hub memories with many incoming edges rank higher
- Log-transform on access count prevents Matthew effect
- Weights configurable via env vars, auto-normalized to sum to 1.0
- On keyword fallback (no embedding), importance replaces similarity at 40% weight

#### 3. Tiered Auto-Linking with Human-in-the-Loop (HIGH)

At `remember()` time:
- Compute embedding similarity against all existing memories
- `>= 0.75`: auto-create edge (high confidence)
- `0.675-0.75`: surface as suggestion (medium confidence)
- Edge type classified by small LLM (qwen3:1.7b) in **single batch call** — one inference for N pairs
- LLM explicitly forbidden from outputting "supersedes" (redirected to "contradicts")
- `memory_supersede` tool docstring: "HUMAN-ONLY ACTION"

#### 4. Typed Edge Vocabulary (MEDIUM)

6 standard types + custom allowed:
- `supersedes` (directional), `relates_to` (bidirectional), `derived_from` (directional)
- `contradicts` (bidirectional), `exemplifies` (directional), `refines` (directional)
- Each edge: `strength` (0-1), `bidirectional` flag, `edge_metadata` (JSON)
- Unique constraint on `(source_id, target_id, relation_type)`
- Alias normalization for LLM output resilience (derives→derived_from, contradict→contradicts, etc.)

#### 5. Embedding Metadata Injection (MEDIUM)

`embedding_text()` prefixes content with `[memory_type] [project:X] subject content`. Memories of different types/projects naturally cluster differently in vector space. Zero-cost, no extra infra.

#### 6. Graph Traversal (MEDIUM)

BFS from start node, up to depth 5. Filters by relation type, direction (out/in/both), min strength. Respects bidirectional flag. Results grouped by depth + all discovered edges.

Centrality-protected archival: memories with high in-degree skip batch archival/stale detection even if old and rarely accessed directly.

#### 7. Cross-Instance Handoff (LOW-MEDIUM)

Async message-passing between Claude instances (desktop, code, web). Message types: handoff, status, question, fyi, context. Instance IDs validated against config. Supports broadcasts (`to_instance="all"`).

#### 8. Proactive Tool Docstrings (LOW)

MCP tool descriptions engineered to instruct Claude: "STORE MEMORIES WITHOUT BEING ASKED", "USE THIS TOOL AS A REFLEX, NOT AN OPTION", "NOT using this when context might exist is a failure mode." Prompt engineering at tool-definition level.

### What memory-palace Lacks (memory-mcp is better)

- **No consciousness surface** — no CLAUDE.md equivalent, no session-start context push. Everything is pull-via-tool. Token-expensive if Claude has to query every session.
- **No hook-based extraction** — requires explicit tool calls or `memory_reflect` invocation. No silent capture.
- **No confidence decay** — basic archival + access tracking but no nuanced decay model per category.
- **No line-budgeted generation** — no concept of fitting memories into a token budget.
- **No git awareness** — no branch tagging, no commit context.
- **Local-only inference** — requires Ollama + GPU. No API-based option for cloud-only setups.

### Key Architectural Insight

**Best system = push + pull hybrid:**
- CLAUDE.md (from memory-mcp) for token-efficient session-start consciousness
- MCP tools (from memory-palace) for on-demand mid-session retrieval
- Hook-based extraction (memory-mcp) for zero-friction capture
- Graph + centrality (memory-palace) for relationship-aware ranking

Neither system alone is optimal. The fork should combine both paradigms.

---

## Neumann-Inspired Enhancements

Analysis of [Shadylukin/Neumann](https://github.com/Shadylukin/Neumann) — a unified tensor DB combining relational, graph, and vector storage with semantic conflict resolution.

### Key Patterns Worth Adopting

#### 1. Geometric Conflict Classification (replaces binary dedup)

Neumann classifies changes by embedding similarity:
```
< 0.1  → orthogonal (auto-merge, completely different)
0.1-0.5 → partial overlap (review, related but distinct)
> 0.5  → direct conflict (merge/dedupe)
```

**Application**: Instead of "is duplicate? yes/no", classify memory pairs:
- `< 0.1`: Keep both, no relation
- `0.1-0.5`: Keep both, add `related_to` edge
- `> 0.5`: Dedupe via LLM consolidation

More nuanced than current "escalate 0.3-0.6 to LLM" plan.

#### 2. Three-Tier Caching for Consciousness

Neumann's cache lookup:
```
1. Exact match (O(1) hash) — tried first
2. Semantic similarity (O(log n) HNSW) — fallback
3. Embedding lookup (O(1)) — final fallback
```

**Application** for session-adaptive consciousness:
1. **Exact**: Has this cwd/branch been seen? Use cached surface.
2. **Semantic**: Find memories related to current context via embedding.
3. **Fallback**: Generic top-N by recency/priority.

#### 3. Delta Vectors for Change Tracking

Neumann stores `before → after` with delta vectors, threshold `> 0.01`:
> "Only capture differences > 0.01"

**Application**: Store memory updates as deltas from original:
- Initial memory = base
- Updates = deltas (what changed)
- Consolidation merges deltas into new base

Reduces storage, improves dedup — similar memories have similar delta patterns.

#### 4. Pre-Consolidation Checkpoints

> "Manual and automatic checkpoints before destructive operations"

**Application**: Before any consolidation/prune, snapshot `state.json`. Enables rollback if consolidation goes wrong. Simple: `state.json.checkpoint.{timestamp}`.

#### 5. Hot/Cold Memory Tiers

Neumann's tiered storage:
```
Hot: In-memory (fast, frequently accessed)
Cold: mmap-backed files (slower, rarely accessed)
```

**Application**:
- Hot: Recent, pinned, high-priority → always in CLAUDE.md
- Cold: Older, low-priority → state.json only, surfaced via MCP tool on-demand

#### 6. Memory Graph Edges (not just tags)

Neumann uses typed graph edges for relationships + permissions.

**Application**: Add `edges` field to memories:
```json
{
  "id": "mem_123",
  "edges": [
    { "type": "related_to", "target": "mem_456" },
    { "type": "supersedes", "target": "mem_789" }
  ]
}
```

Auto-populate during extraction: ask Haiku "which existing memories relate to this?"

#### 7. Dynamic Metric Selection

Neumann switches similarity metric based on sparsity:
- Dense embeddings → Cosine
- Sparse (>50% zeros) → Jaccard

**Application**: If using embeddings for dedup, detect sparsity and adjust. Haiku-generated fingerprints may be sparse.

### Implementation Priority

**Tier 1 (High Impact):**
1. Geometric three-tier dedup (orthogonal/partial/conflict)
2. Memory graph edges with `related_to`
3. Pre-consolidation checkpoints

**Tier 2 (Medium Impact):**
4. Hot/cold memory split
5. Delta-based memory updates
6. Dynamic metric selection

**Tier 3 (Lower Priority):**
7. Memory state machine (enforce valid transitions)
8. Archetype clustering (store as deltas from category centroid)

### Comparison: Original Plan vs Enhanced

| Gap | Original Approach | Neumann-Enhanced |
|-----|-------------------|------------------|
| Weak dedup | Hybrid Jaccard + LLM escalation | Three-tier geometric (0.1/0.5 thresholds) |
| No relationships | Tags only | Graph edges with typed relationships |
| Static consciousness | Session-adaptive rendering | Three-tier cache (exact/semantic/fallback) |
| No rollback | None | Checkpoint before consolidation |
| All memories equal | Pinning/priority | Hot/cold tiers + archetype compression |

### Reassessment After memory-palace Analysis

Some Neumann patterns overlap with or are superseded by memory-palace's simpler implementations:

| Neumann Pattern | Verdict | Reason |
|-----------------|---------|--------|
| Geometric three-tier dedup | **Keep** | More nuanced than memory-palace's binary threshold |
| Memory graph edges | **Merge** — adopt memory-palace's typed vocabulary + Neumann's similarity-based auto-creation |  |
| Pre-consolidation checkpoints | **Keep** | memory-palace doesn't have this, still valuable |
| Hot/cold memory tiers | **Simplify** — memory-palace's centrality-weighted ranking achieves similar effect without explicit tiers |  |
| Delta vectors | **Drop** | Over-engineering for short text memories. memory-palace's supersession is simpler |
| Dynamic metric selection | **Drop** | Uniform embeddings (single model) make this unnecessary |
| Archetype clustering | **Drop** | Academic, unclear practical value |
| Three-tier cache | **Simplify** — keep branch/cwd exact cache, drop HNSW tier for <1000 memories |  |

---

## Combined Implementation Priority (All Sources)

**Phase 1 — Core Hybrid Architecture:**
1. MCP tool surface (recall, remember, forget, get) — enables pull alongside push
2. Prose-code pairing for code memory
3. Typed edge vocabulary (6 types + strength + direction)
4. Centrality-weighted retrieval ranking
5. Supersession safety (human-only)

**Phase 2 — Enhanced Intelligence:**
6. Git context injection to extractor
7. Hybrid dedup (Jaccard first pass → geometric classification → LLM consolidation)
8. Auto-linking with tiered confidence (auto/suggest)
9. Batch LLM edge classification
10. Pre-consolidation checkpoints

**Phase 3 — Polish:**
11. Provenance + access tracking
12. Pinning/priority fields
13. Embedding metadata injection (`[type] [project:X]` prefix)
14. Proactive tool docstrings
15. Error logging
16. Session-adaptive consciousness (branch/cwd cache)
