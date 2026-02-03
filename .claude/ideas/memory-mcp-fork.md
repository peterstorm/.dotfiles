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

### 6. Error Handling Fully Silent (LOW)

Every catch block swallows errors. Good for not disrupting Claude, bad for debugging.

Improvement: Write errors to `.memory/errors.log` with timestamps. Still silent to Claude, but debuggable. Add `memory-mcp status` to surface recent errors.

## Architecture Decision: Fork vs Build From Scratch

**Recommendation: Fork.**

The core architecture (two-tier, hooks, lifecycle, consolidation) is the hard part and it's done well. The improvements are additive — better dedup, git awareness, pinning — not architectural rewrites.

Fork strategy:
1. Fork yuvalsuede/memory-mcp
2. Add git context injection to extractor
3. Improve dedup with hybrid Jaccard + LLM escalation
4. Add pinning/priority fields
5. Add error logging
6. Optional: session-adaptive consciousness

## Unresolved Questions

- Embeddings vs LLM-based semantic dedup? Embeddings are faster but add dependency. LLM dedup during consolidation is simpler.
- How much git context to inject? Full diff is too much. `git log --oneline -5` + `git diff --stat` + branch name seems right.
- Store per-project or global? Current is per-project (`.memory/` in project dir). Cross-project memory could be valuable but complex.
- Should consciousness adapt per-session or stay static? Adaptive is smarter but harder to debug.
- Worth adding a `memory_pin` MCP tool or just a `pinned` field on `memory_save`?
- Three-tier geometric dedup vs hybrid Jaccard+LLM — which cheaper/better?
- Graph edges: store in state.json or separate graph file?
- Hot/cold: surface cold memories via MCP tool or include IDs in CLAUDE.md for on-demand fetch?
- Checkpoint storage: same file with version suffix, or separate checkpoint dir?

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
