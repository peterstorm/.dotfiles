# Feature: Cortex - Persistent Memory Plugin

**Spec ID:** 2026-02-06-cortex
**Created:** 2026-02-06
**Status:** Draft
**Owner:** hansen142

## Summary

Cortex gives Claude Code persistent, project-aware memory with semantic search and code indexing. Captures knowledge from conversations automatically, surfaces critical context at session start via push surface, provides on-demand recall mid-session. Differentiator is code-aware memory: prose descriptions paired with actual code, enabling "how does auth work?" queries that return both explanation and implementation.

---

## User Scenarios

### US1: [P1] Automatic Memory Capture

**As a** developer using Claude Code across multiple sessions
**I want** Claude to automatically remember architectural decisions, patterns, and gotchas from past conversations
**So that** I don't have to repeatedly explain project context in new sessions

**Why P1:** Core value proposition. Without automatic capture, system provides no value.

**Acceptance Scenarios:**
- Given session ends, When Stop hook runs, Then new memories extracted from transcript and stored without user action
- Given memory about architecture decision made in session, When next session starts, Then decision visible in push surface
- Given extraction fails (API unavailable), When Stop hook runs, Then extraction deferred but session continues normally (offline-capable)
- Given duplicate memory (>0.7 similarity), When extraction runs, Then flagged for auto-consolidation, not stored as duplicate

### US2: [P1] Push Surface - Critical Context at Session Start

**As a** developer starting new Claude Code session
**I want** most critical/relevant memories automatically visible to Claude
**So that** Claude has project context without querying

**Why P1:** Push surface is primary UX. Without it, user must explicitly recall memories every session.

**Acceptance Scenarios:**
- Given session starts in project directory, When Claude loads context, Then `.claude/cortex-memory.local.md` auto-loaded with tiered memories (critical/context-specific/code-index)
- Given 200+ memories in DB, When push surface generates, Then limited to ~300-500 tokens (critical tier only)
- Given pinned memory, When push surface generates, Then pinned memory always included regardless of age/confidence
- Given branch/cwd context matches cached surface, When push surface generates, Then cached version loaded (no regeneration)

### US3: [P1] Semantic Search via /recall

**As a** developer mid-session needing specific context
**I want** to query memories semantically (not keyword match)
**So that** I can retrieve "how does auth work?" even if exact words differ

**Why P1:** Query-driven retrieval complements push surface. Enables pull-based access.

**Acceptance Scenarios:**
- Given query "authentication flow", When `/recall authentication flow` invoked, Then memories about auth retrieved ranked by relevance (embeddings + centrality + confidence)
- Given offline (Voyage API unavailable), When `/recall` invoked, Then fallback to FTS5 keyword search instead of embedding similarity
- Given query matches prose-code pair, When `/recall` invoked, Then both prose description and linked raw code returned
- Given 100+ candidate memories, When `/recall` runs, Then only top 10 returned to Claude for final ranking (token budget)

### US4: [P1] Code Indexing - Prose-Code Pairing

**As a** developer wanting to preserve implementation knowledge
**I want** to index code files with prose descriptions
**So that** semantic queries like "payment processing logic" retrieve actual implementation code

**Why P1:** Key differentiator vs generic knowledge graphs. Code-aware memory highest-value feature.

**Acceptance Scenarios:**
- Given code file path, When `/index-code src/payment/processor.ts` invoked, Then Claude generates prose summary, system stores prose+code as linked pair (source_of edge)
- Given indexed code file changes, When re-indexed with force flag, Then old prose-code pair superseded, new pair stored
- Given query "how payment works", When `/recall payment` invoked, Then prose description retrieved, follows edge to raw code block
- Given code block, When stored, Then NOT embedded (raw storage only), prose embedded instead

### US5: [P2] Explicit Memory Creation via /remember

**As a** developer with specific knowledge to preserve
**I want** to manually save memories without waiting for session end
**So that** critical decisions captured immediately

**Why P2:** Useful but not core flow. Auto-extraction primary mechanism.

**Acceptance Scenarios:**
- Given text input, When `/remember "use Zustand for client state"` invoked, Then memory created immediately, embedding queued for background generation
- Given memory type specified, When `/remember --type decision "..."` invoked, Then memory tagged with correct type (architecture/decision/pattern/gotcha/progress/context/code_description)
- Given priority specified, When `/remember --priority 10 "..."` invoked, Then memory stored with high priority (influences push surface ranking)

### US6: [P2] Memory Relationships - Typed Graph Edges

**As a** developer with interconnected knowledge
**I want** memories to link to related memories
**So that** retrieving one memory surfaces related context

**Why P2:** Enhances recall quality via centrality weighting. Not critical for v1.

**Acceptance Scenarios:**
- Given new memory extracted, When similarity to existing memory >0.1, Then `relates_to` edge auto-created
- Given new memory contradicts existing, When auto-link runs, Then `contradicts` edge created (bidirectional)
- Given memory with high in-degree centrality (hub), When push surface generates, Then centrality boosts ranking (15% weight)
- Given memory supersedes another, When `/forget` invoked on old memory, Then supersedes edge created (human-only action, LLM cannot create)

### US7: [P2] Memory Consolidation

**As a** developer with redundant memories accumulating
**I want** system to merge similar memories
**So that** memory store stays clean without manual maintenance

**Why P2:** Quality-of-life feature. System degrades gracefully without it.

**Acceptance Scenarios:**
- Given 10 extractions since last consolidation, When Stop hook runs, Then consolidation triggered automatically
- Given memories with >0.7 similarity (auto) or >0.5 (manual), When consolidation runs, Then LLM merges content, old memories archived (not deleted), new merged memory active
- Given consolidation fails mid-process, When error occurs, Then DB rolled back from checkpoint (pre-consolidation snapshot)
- Given manual trigger, When `/consolidate` invoked, Then Claude reviews merge proposals, user approves/rejects

### US8: [P3] Memory Lifecycle - Confidence Decay

**As a** developer with aging memories
**I want** old/stale memories to fade naturally
**So that** push surface reflects current state, not outdated info

**Why P3:** Nice-to-have quality control. Not critical for v1.

**Acceptance Scenarios:**
- Given progress memory, When 7 days pass without access/update, Then confidence decayed to 50%
- Given pattern memory, When 60 days pass, Then confidence decayed to 50%
- Given architecture/decision memory, When time passes, Then no decay (stable type)
- Given memory with confidence <0.3 for 14 days, When lifecycle runs, Then status changed to archived
- Given pinned memory, When time passes, Then no decay applied

### US9: [P3] Memory Forgetting via /forget

**As a** developer with incorrect/outdated memory
**I want** to remove or archive memories
**So that** bad information doesn't pollute future sessions

**Why P3:** Cleanup mechanism. Manual workaround exists (edit .memory/cortex.db).

**Acceptance Scenarios:**
- Given memory ID, When `/forget mem_12345` invoked, Then memory status changed to archived
- Given fuzzy query, When `/forget "old auth pattern"` invoked, Then matching memory found and archived
- Given archived memory, When 30 days pass untouched, Then status changed to pruned (deleted from DB)

---

## Functional Requirements

### Core - Memory Extraction

- FR-001: System MUST extract memories from conversation transcript at session end (Stop hook)
- FR-002: System MUST track extraction cursor position to only process new transcript content (incremental)
- FR-003: System MUST classify extracted memories by type: architecture, decision, pattern, gotcha, progress, context, code_description, code
- FR-003a: System MUST classify memories as global vs project using hybrid approach: LLM suggests category during extraction, confidence >0.8 auto-classifies as global, otherwise defaults to project
- FR-004: System MUST generate embeddings for memories using Voyage AI (voyage-3.5-lite, 1024d vectors)
- FR-005: System SHOULD fallback to local embeddings (@huggingface/transformers all-MiniLM-L6-v2, 384d) when Voyage API unavailable
- FR-006: System MUST store embeddings as BLOB in SQLite (separate columns for voyage_embedding and local_embedding)
- FR-007: System MUST extract up to 65,000 chars of transcript per session (configured limit)
- FR-008: System MUST degrade gracefully if extraction fails (log error, don't block session end)

### Core - Memory Storage

- FR-010: System MUST store memories in SQLite with fields: id (uuid), content (TEXT), summary (TEXT), memory_type, category (project/global), embedding (BLOB), confidence (0-1), priority (1-10), pinned (bool), source_type, source_session, source_context, tags (JSON), access_count, last_accessed_at, created_at, updated_at, status (active/superseded/archived/pruned)
- FR-011: System MUST store project memories in `.memory/cortex.db` per project
- FR-012: System MUST store global memories in `~/.claude/memory/cortex-global.db`
- FR-013: System MUST enable SQLite WAL mode for concurrent read/write safety
- FR-014: System MUST track extraction state in `extractions` table: id, session_id, cursor_position, extracted_at
- FR-015: System MUST store memory relationships in `edges` table: id, source_id, target_id, relation_type, strength (0-1), bidirectional (bool), created_at
- FR-016: System MUST enforce unique constraint on (source_id, target_id, relation_type) for edges

### Core - Push Surface Generation

- FR-020: System MUST generate `.claude/cortex-memory.local.md` at session end (after extraction)
- FR-021: System MUST target 300-500 tokens for push surface, dynamically adjusted based on memory quality (no hard cap, allow overflow for high-value memories)
- FR-022: System MUST rank memories using formula: `(confidence * 0.5) + (priority/10 * 0.2) + (centrality * 0.15) + (log(access_count+1)/max_log * 0.15)`
- FR-023: System MUST organize push surface by tier: Critical (top 10-15 memories), Context-Specific (current branch/file), Code Index (key indexed files)
- FR-024: System MUST preserve manually-edited sections of cortex-memory.local.md outside generation markers
- FR-025: System MUST include pinned memories in push surface regardless of ranking score
- FR-026: System MAY cache branch/cwd-specific push surfaces for fast session start (optional optimization)

### Core - Semantic Search

- FR-030: System MUST provide `/recall <query>` skill for semantic memory retrieval
- FR-031: System MUST retrieve candidates using embedding similarity (cosine distance on Voyage embeddings)
- FR-032: System MUST fallback to SQLite FTS5 keyword search when embeddings unavailable (offline mode)
- FR-033: System MUST search both project DB and global DB, returning merged results
- FR-034: System MUST return top 10 candidates to Claude for final relevance ranking (token budget)
- FR-035: System MUST update access_count and last_accessed_at when memory retrieved via /recall
- FR-036: System MUST follow `source_of` edges from prose memories to retrieve linked raw code

### Core - Code Indexing

- FR-040: System MUST provide `/index-code <path>` skill for creating prose-code pairs
- FR-041: System MUST instruct Claude to generate prose summary of code file (runs in subscription)
- FR-042: System MUST store prose as `code_description` memory type with embedding
- FR-043: System MUST store raw code as `code` memory type WITHOUT embedding (raw storage only)
- FR-044: System MUST create `source_of` edge (directional) from prose to code memory
- FR-045: System MUST support force re-indexing (supersedes old prose-code pair)
- FR-046: System MAY auto-trigger indexing on Write/Edit tool calls (deferred to v2, manual-only for v1)

### Core - Explicit Memory Creation

- FR-050: System MUST provide `/remember <text>` skill for manual memory creation
- FR-051: System MUST queue embedding generation for background processing (don't block skill return)
- FR-052: System MUST support --type flag (architecture/decision/pattern/gotcha/progress/context)
- FR-053: System MUST support --priority flag (1-10, default 5)
- FR-054: System MUST support --global flag (store in global DB instead of project DB)
- FR-055: System MUST support --pin flag (marks memory as pinned, skips decay)

### Advanced - Graph Edges

- FR-060: System MUST auto-create edges when extracting new memories (similarity-based)
- FR-061: System MUST create `relates_to` edge when similarity 0.1-0.5 (bidirectional)
- FR-062: System MUST flag for consolidation when similarity >0.7 (auto-consolidation threshold), manual /consolidate uses >0.5
- FR-063: System MUST classify edge types in batch LLM call (one inference for N pairs): relates_to, derived_from, contradicts, exemplifies, refines, supersedes, source_of
- FR-064: System MUST forbid LLM from creating `supersedes` edges (human-only action, redirect to contradicts if attempted)
- FR-065: System MUST compute in-degree centrality for memories (simple count of incoming edges, not PageRank)
- FR-066: System MUST use centrality as 15% weight in ranking formula
- FR-067: System MUST support edge strength (0-1 float) for weighted graph traversal

### Advanced - Memory Consolidation

- FR-070: System MUST trigger consolidation after 10 extractions, OR when >80 active memories, OR explicit `/consolidate` invocation
- FR-071: System MUST checkpoint DB state before consolidation (pre-consolidation snapshot)
- FR-072: System MUST group memories by type + high similarity for consolidation (>0.7 auto-consolidation, >0.5 manual /consolidate)
- FR-073: System MUST send groups to LLM (Haiku) with prompt: "merge if redundant, preserve unique details"
- FR-074: System MUST create new merged memory with status=active, archive old memories (not delete)
- FR-075: System MUST rollback from checkpoint if consolidation fails
- FR-076: System MUST provide `/consolidate` skill for manual trigger with Claude review step

### Advanced - Lifecycle Management

- FR-080: System MUST apply confidence decay based on memory type: progress (7d half-life), gotcha (45d), pattern (60d), context (30d), architecture/decision/code_description (stable, no decay)
- FR-081: System MUST use formula: `confidence = initial_confidence * (0.5 ^ (days_since_update / half_life))`
- FR-082: System MUST skip decay for pinned memories (pinned=true)
- FR-083: System MUST double half-life for memories with access_count >10
- FR-084: System MUST double half-life for memories with centrality >0.5
- FR-085: System MUST transition status: active → (confidence <0.3 for 14d) → archived
- FR-086: System MUST transition status: archived → (30d untouched) → pruned (deleted)
- FR-087: System MUST restore archived memory to active if accessed via /recall

### Advanced - Context Awareness

- FR-090: System MUST gather git context before extraction: current branch, recent commits (last 5), changed files (git diff --stat)
- FR-091: System MUST tag memories with branch name in source_context field
- FR-092: System MUST differentiate branch-specific progress memories from cross-branch architecture memories
- FR-093: System MUST include git context in extraction prompt to LLM

### Skills

- FR-100: System MUST provide `/recall <query>` skill (semantic search)
- FR-101: System MUST provide `/remember <text>` skill (explicit save with optional flags: --type, --priority, --global, --pin)
- FR-102: System MUST provide `/index-code <path>` skill (prose-code pairing)
- FR-103: System MUST provide `/forget <id|query>` skill (archive memory)
- FR-104: System MUST provide `/consolidate` skill (manual consolidation trigger)

---

## Non-Functional Requirements

### Performance

- NFR-001: Extraction MUST complete in <30 seconds (p95) for 65k char transcript
- NFR-002: Push surface generation MUST complete in <5 seconds (p95)
- NFR-003: `/recall` MUST return candidates in <2 seconds (p95) for 1000 memories
- NFR-004: Embedding generation MUST be asynchronous (don't block /remember return)
- NFR-005: System MUST handle 10,000+ memories without performance degradation

### Reliability

- NFR-010: System MUST degrade gracefully when Voyage API unavailable (fallback to local embeddings for /recall, queue Voyage embeddings for background async generation at next session start)
- NFR-011: System MUST degrade gracefully when Haiku API unavailable (skip extraction, queue for next session)
- NFR-012: System MUST use SQLite WAL mode to prevent DB corruption from concurrent access
- NFR-013: System MUST checkpoint DB before destructive operations (consolidation, pruning)
- NFR-014: System MUST log errors to `.memory/cortex.log` without disrupting Claude session

### Cost

- NFR-020: Extraction + embeddings + auto-linking MUST cost <$0.10/day for active development (assumes 10 sessions/day, 5k tokens avg transcript per session)
- NFR-021: Voyage AI embeddings MUST stay within 200M tokens/month free tier for typical usage
- NFR-022: Haiku API calls (extraction, consolidation, edge classification) MUST cost <$0.05/day

### Security

- NFR-030: System MUST store embeddings as binary BLOB (not plaintext)
- NFR-031: System MUST NOT transmit code content to embedding API (prose-code pairing: only prose embedded, code stored locally)
- NFR-032: System MUST store API keys in environment variables (ANTHROPIC_API_KEY, VOYAGE_API_KEY)
- NFR-033: System MUST respect .gitignore for `.memory/` directory (auto-generated .gitignore entry)

### Compatibility

- NFR-040: System MUST use bun as primary runtime to match existing `.claude/hooks/ts-utils/` infrastructure
- NFR-041: System SHOULD compile TypeScript to JavaScript for Node.js compatibility where bun unavailable (optional portability)
- NFR-042: System MUST compile TypeScript to JavaScript for bundled distribution
- NFR-043: System MUST work offline (degrade to FTS5 search, queue embeddings/extraction)

---

## Success Criteria

- SC-001: 90% of sessions successfully extract at least 1 memory (extraction reliability)
- SC-002: Push surface includes at least 5 relevant memories for 80% of sessions (push surface quality)
- SC-003: `/recall` queries return at least 1 relevant result for 85% of queries (semantic search accuracy)
- SC-004: Code indexing creates valid prose-code pairs for 95% of indexed files (code indexing success rate)
- SC-005: Consolidation reduces duplicate memories by 60% when triggered (dedup effectiveness)
- SC-006: Confidence decay correctly archives memories: progress memories archived after ~14d of no access, patterns after ~120d (lifecycle correctness)
- SC-007: System costs <$0.15/day for 10 active sessions/day (cost target)
- SC-008: Zero DB corruption events across 1000 sessions (reliability target)
- SC-009: Offline mode works: `/recall` falls back to FTS5, extraction queued, no session blocking (offline capability)
- SC-010: Users report not needing to re-explain project context in >70% of multi-session workflows (user value metric)

**Measurement approach:**
- Instrumentation: log extraction success/failure, push surface generation time, recall query relevance (Claude ranks 1-5), consolidation merge counts
- Cost tracking: log API call counts + token usage to `.memory/cortex-metrics.json`
- User feedback: optional `/cortex-feedback` skill to rate memory usefulness
- Automated tests: lifecycle decay math, ranking formula correctness, offline fallback behavior

---

## Out of Scope

Explicitly NOT part of this feature (v1):

- **Intra-session agent communication** - SubagentStop summaries, work context injection between agents in same session (clnode's domain, not cross-session memory)
- **Web UI / dashboard** - push surface + skills sufficient, no separate interface
- **Multi-user collaboration** - single-user focus, no shared memory across developers
- **Version control integration beyond file paths** - no git blame, commit linking, diff embedding
- **Automatic memory consolidation UI** - manual `/consolidate` only for v1, auto-consolidation background-only
- **Memory export/import** - no markdown export, no bulk import from other projects
- **Batch code indexing** - `/index-code` manual per-file only, no recursive directory indexing
- **Real-time memory updates during session** - memories extracted at session end only, not during
- **Memory visualization** - no graph UI, no relationship explorer
- **Advanced graph queries** - no BFS traversal, no multi-hop relationship queries (just direct edge following)
- **Memory permissions/sharing** - no ACLs, no team features
- **Integration with external knowledge bases** - no Confluence, Notion, etc.

---

## Open Questions

All questions resolved. Summary of key decisions:

1. ~~Global vs project memory classification~~ RESOLVED: Hybrid approach - LLM suggests, >0.8 confidence auto-global, else project (FR-003a)
2. ~~Push surface token budget~~ RESOLVED: Dynamic 300-500 tokens based on quality, no hard cap (FR-021)
3. ~~Embedding backfill strategy~~ RESOLVED: Background async job at next session start (NFR-010)
4. ~~Graph centrality calculation~~ RESOLVED: In-degree counting, not PageRank (FR-065)
5. ~~/index-code auto-trigger~~ RESOLVED: Manual-only for v1 (FR-046)
6. ~~CLAUDE.md location~~ RESOLVED: `.claude/cortex-memory.local.md` (auto-loaded by Claude Code)
7. ~~Local embedding model~~ RESOLVED: all-MiniLM-L6-v2 via @huggingface/transformers (FR-005)
8. ~~Consolidation threshold~~ RESOLVED: Two-tier - 0.7 for auto, 0.5 for manual (FR-062, FR-072)
9. ~~Stop hook transcript format~~ RESOLVED: JSON on stdin with `{ session_id, transcript_path, cwd }`, transcript is JSONL
10. ~~Memory pinning UI~~ RESOLVED: --pin flag on /remember (FR-055)

---

## Dependencies

External factors this feature depends on:

- **Claude Code plugin system** - hooks (Stop), skills (markdown format), agents (subagent invocation for extraction)
- **Voyage AI API** - embedding generation (voyage-3.5-lite), 200M tokens/month free tier
- **Anthropic API** - Haiku for extraction, edge classification, consolidation (~$0.25/million input tokens)
- **@huggingface/transformers** - local embedding fallback, must work in bun runtime
- **better-sqlite3** - native SQLite binding for Node.js/bun, WAL mode support
- **Git** - git commands for context gathering (branch, log, diff), assumes git repo exists
- **Bun runtime** - TypeScript execution, replaces node.js for hook invocation
- **SQLite FTS5** - full-text search extension for offline keyword fallback

---

## Risks

Known risks and mitigation thoughts (not solutions):

| Risk | Impact | Mitigation Direction |
|------|--------|---------------------|
| Voyage API rate limits exceeded | High | Implement request queuing, backoff retry, cache embeddings aggressively |
| Token budget creep - push surface grows beyond 500 tokens | Medium | Hard cap at 500 tokens, prioritize ruthlessly, monitor metrics |
| Bad consolidation merges unrelated memories | Medium | Pre-consolidation checkpoints, human review for `/consolidate`, LLM prompt refinement |
| DB corruption from concurrent writes | High | WAL mode, atomic writes, file locking, backup/restore mechanism |
| Memory pollution from bad extractions | Medium | Confidence decay handles naturally, `/forget` for manual cleanup, consolidation reduces noise |
| Offline mode degrades too much (FTS5 poor results) | Low | FTS5 acceptable for exact keyword match, queue embeddings for next online session |
| Cost overrun (>$0.15/day) | Medium | Monitor token usage, adjust consolidation frequency, consider local embeddings as primary |
| Extraction latency blocks session end | Low | Timeout extraction at 30s, queue for background retry, don't block user |
| Graph edges create "hairball" (too many relates_to edges) | Low | Threshold tuning (0.1 may be too low), edge strength decay over time |
| Global memory namespace collisions (two projects use "auth") | Medium | Prefix with project name in embedding metadata, search scoping by project first |

---

## Appendix: Glossary

| Term | Definition |
|------|------------|
| **Memory** | Single unit of knowledge extracted from conversation or explicitly saved. Has type, content, embedding, confidence, relationships. |
| **Push surface** | `.claude/cortex-memory.local.md` file auto-loaded by Claude Code at session start. Contains ~300-500 tokens of critical memories. |
| **Pull mechanism** | On-demand retrieval via `/recall` skill during session. Complements push surface. |
| **Prose-code pairing** | Two-part memory: (1) LLM-generated prose description (embedded for search), (2) raw code (not embedded), linked via `source_of` edge. |
| **Embedding** | 1024d float vector (Voyage) or 384d float vector (local) representing semantic content. Used for cosine similarity search. |
| **Edge** | Directed or bidirectional relationship between memories. Types: relates_to, derived_from, contradicts, exemplifies, refines, supersedes, source_of. |
| **Centrality** | Graph metric: in-degree count (how many edges point to this memory). Hub memories have high centrality. |
| **Confidence** | 0-1 score representing memory freshness. Decays over time based on memory type. <0.3 → archived. |
| **Consolidation** | Process of merging similar memories to reduce redundancy. LLM-driven, creates merged memory + archives old. |
| **Extraction** | Automated process at session end: parse transcript → send to Haiku → extract structured memories → store in DB. |
| **Lifecycle** | Status transitions: active → archived (low confidence) → pruned (deleted after 30d). |
| **WAL mode** | SQLite write-ahead logging. Allows concurrent readers during writes. Prevents corruption. |
| **FTS5** | SQLite full-text search extension. Used for keyword fallback when embeddings unavailable (offline). |
| **Session cursor** | Position in transcript where last extraction ended. Enables incremental processing (don't re-extract old content). |
| **Global memory** | Knowledge stored in `~/.claude/memory/cortex-global.db`, shared across projects. Example: language patterns, framework choices. |
| **Project memory** | Knowledge stored in `.memory/cortex.db` per project. Example: architectural decisions, file locations. |
| **Pinned memory** | Memory marked with `pinned=true`. Never decays, never consolidated, always in push surface. |
| **Supersession** | One memory replaces another (human-only action). Old memory archived, supersedes edge created. LLM cannot auto-supersede. |

---

## Change Log

| Date | Change | Author |
|------|--------|--------|
| 2026-02-06 | Initial draft | hansen142 |
