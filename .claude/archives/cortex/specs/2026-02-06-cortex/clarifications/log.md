# Clarification Log - Cortex Specification

## 2026-02-06: Initial Clarification Session

### Resolved from Decisions Doc (No User Input Required)

#### Runtime Conflict (NFR-040/NFR-041)
**Issue:** Conflicting requirements - "Node.js environments" vs "bun as runtime"
**Resolution:** Bun is primary runtime (matches existing `.claude/hooks/ts-utils/`), optional TS→JS compilation for Node.js portability
**Updated:** NFR-040, NFR-041
**Rationale:** Decisions doc clearly states bun is the runtime, TypeScript compiles to JS for portability

#### Push Surface Location (Question 6)
**Issue:** Append to CLAUDE.md vs separate file?
**Resolution:** `.claude/cortex-memory.local.md` (auto-loaded, auto-gitignored)
**Updated:** Open Question 6
**Rationale:** Decisions doc #7 states push mechanism uses `.claude/cortex-memory.local.md`

#### Stop Hook Input Format (Question 9)
**Issue:** JSON stdin vs direct transcript?
**Resolution:** JSON on stdin with `{ session_id, transcript_path, cwd }`, transcript is JSONL file at transcript_path
**Updated:** Open Question 9
**Rationale:** Decisions doc #11 clarifies Stop hook receives JSON stdin with transcript_path field

#### Graph Centrality Calculation (Question 4)
**Issue:** PageRank-style (iterative) vs in-degree counting?
**Resolution:** Simple in-degree counting (count of incoming edges)
**Updated:** FR-065, Open Question 4
**Rationale:** memory-mcp-fork.md confirms in-degree sufficient for <1000 memories, simpler implementation

#### /index-code Auto-trigger (Question 5)
**Issue:** Auto-trigger on Write/Edit or manual-only?
**Resolution:** Manual-only for v1
**Updated:** FR-046, Open Question 5
**Rationale:** FR-046 already defers auto-trigger to v2, avoids noise from trivial edits

#### Memory Pinning UI (Question 10)
**Issue:** Separate /pin skill vs --pin flag on /remember?
**Resolution:** --pin flag on /remember
**Updated:** FR-055, Open Question 10
**Rationale:** FR-055 already shows --pin flag pattern, reduces skill proliferation

---

## 2026-02-06: User Clarification Batch 1

### Cost Model Assumptions (NFR-020)

**Question:** What usage pattern for cost calculations?
**Answer:** Option A - 10 sessions/day, 5k tokens avg transcript per session
**Updated:** NFR-020
**Rationale:** Baseline active development pattern for budgeting Voyage/Haiku API usage, maps to ~50k tokens/day extraction

### Push Surface Token Budget (Question 2)

**Question:** Hard limit or dynamic token budget for push surface?
**Answer:** Option B - Dynamic 300-500 based on memory quality, allow overflow for high-value memories
**Updated:** FR-021
**Rationale:** Prioritizes critical context visibility over strict budgeting, ranking algorithm handles quality filtering

### Embedding Backfill Strategy (Question 3)

**Question:** How to backfill embeddings after offline period?
**Answer:** Option A - Background async job at next session start (doesn't block session)
**Updated:** NFR-010
**Rationale:** Balances UX (no session blocking) with performance (async processing), embeddings ready for subsequent sessions

### Local Embedding Model (FR-005, Question 7)

**Question:** Which local model for fallback embeddings?
**Answer:** Option A - all-MiniLM-L6-v2 (384d, standard choice, proven)
**Updated:** FR-005, Open Question 7
**Rationale:** Standard model, verified compatibility with @huggingface/transformers in bun runtime, 384d matches spec

### Consolidation Similarity Threshold (Question 8)

**Question:** Is 0.5 threshold appropriate or too aggressive?
**Answer:** Option D - Two-tier: 0.5 for manual /consolidate, 0.7 for auto-consolidation
**Updated:** FR-062, FR-072, US1, US7, Open Question 8
**Rationale:** Conservative auto-consolidation (0.7) reduces risk of merging distinct memories, manual mode (0.5) allows aggressive deduplication when user reviews

### Global vs Project Memory Classification (Question 1)

**Question:** What qualifies as global vs project memory?
**Answer:** Hybrid - LLM suggests category during extraction, >0.8 confidence auto-classifies as global, otherwise defaults to project
**Updated:** FR-003a (new), Open Question 1
**Rationale:** LLM best positioned to detect language patterns/framework knowledge (global) vs implementation details (project), high confidence threshold ensures accuracy, default-to-project safe fallback

---

## Summary

**Total markers resolved:** 10
**Remaining markers:** 0
**Ready for architecture:** Yes

### Coverage by Category

| Category | Status |
|----------|--------|
| Functional scope | Resolved |
| Data model | Resolved |
| UX flows | Resolved |
| Performance | Resolved |
| Integration | Resolved |
| Edge cases | Resolved |
| Constraints | Resolved |
| Terminology | Resolved |
| Completion | Resolved |

All specification uncertainties resolved. Spec ready for architecture phase.
