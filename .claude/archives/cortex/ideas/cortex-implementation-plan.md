# Cortex — Persistent Memory Plugin for Claude Code

Implementation plan for a native Claude Code plugin that gives Claude persistent, project-aware memory with semantic search, knowledge graph, and code indexing.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Native Claude Code plugin | Leverages existing hook/skill/agent infra. No separate process. |
| Storage | SQLite | Embeddings need float arrays. FTS5 for text search. Handles concurrency via WAL. |
| Embeddings/LLM | Haiku API (minimal) | Background ops only (extraction, embeddings, auto-linking, consolidation). ~$0.02-0.05/day. |
| Interactive LLM | Subscription (Claude itself) | /recall ranking, /index-code prose generation run as skills inside Claude Code. |
| Pull mechanism | Skills (/recall, /remember, etc) | No MCP server. Skills are native to Claude Code plugin system. |
| Push mechanism | CLAUDE.md generation | Stop hook regenerates `## Project Memory` section. Pure ranking algorithm, no LLM. |
| Scope | Per-project + global layer | `.memory/cortex.db` per project. `~/.claude/memory/cortex-global.db` for cross-project knowledge. |
| Code indexing | Prose-code pairing in v1 | Highest-value differentiator. Claude generates prose (subscription), embeddings via Haiku API. |
| Engine | Python CLI | Hooks invoke `python3 -m cortex <cmd>`. Minimal deps: httpx, click. stdlib sqlite3. |

## Data Model

### `memories` table

| Column | Type | Purpose |
|--------|------|---------|
| id | TEXT (uuid) | PK |
| content | TEXT | Full memory text |
| summary | TEXT | One-line for CLAUDE.md rendering |
| memory_type | TEXT | architecture, decision, pattern, gotcha, progress, context, code_description, code |
| category | TEXT | project or global |
| embedding | BLOB | Haiku-generated float array |
| confidence | REAL (0-1) | Decay-aware score |
| priority | INTEGER (1-10) | Ranking weight, default 5 |
| pinned | BOOLEAN | Skip decay + consolidation |
| source_type | TEXT | conversation, explicit, code_index |
| source_session | TEXT | Session ID |
| source_context | TEXT | Branch, file path, etc |
| tags | TEXT (JSON) | Searchable tags |
| access_count | INTEGER | Times retrieved |
| last_accessed_at | TEXT (ISO) | Last retrieval |
| created_at | TEXT (ISO) | |
| updated_at | TEXT (ISO) | |
| status | TEXT | active, superseded, archived, pruned |

### `edges` table

| Column | Type | Purpose |
|--------|------|---------|
| id | TEXT (uuid) | PK |
| source_id | TEXT (FK) | From memory |
| target_id | TEXT (FK) | To memory |
| relation_type | TEXT | relates_to, derived_from, contradicts, exemplifies, refines, supersedes, source_of |
| strength | REAL (0-1) | Edge weight |
| bidirectional | BOOLEAN | |
| created_at | TEXT (ISO) | |

Unique constraint on `(source_id, target_id, relation_type)`.

### `extractions` table

| Column | Type | Purpose |
|--------|------|---------|
| id | TEXT | PK |
| session_id | TEXT | Which session |
| cursor_position | INTEGER | Last processed transcript offset |
| extracted_at | TEXT (ISO) | |

## Operations Map

### Background (Stop hook — API key)

| Operation | LLM? | Cost | Description |
|-----------|-------|------|-------------|
| Extract memories | Haiku | ~$0.001/session | Transcript → structured memories |
| Generate embeddings | Haiku | ~$0.0005/memory | Float vector for similarity search |
| Auto-link edges | Haiku | ~$0.001/batch | Similarity comparison + edge type classification |
| Generate consciousness | None | Free | Rebuild CLAUDE.md `## Project Memory` section |
| Decay + prune | None | Free | Time-based confidence reduction |
| Consolidation | Haiku | ~$0.01/batch | Every ~10 extractions, merge similar memories |

### Interactive (Skills — subscription)

| Skill | LLM? | Description |
|-------|-------|-------------|
| `/recall <query>` | Claude ranks | Python returns SQLite candidates, Claude judges relevance |
| `/remember <text>` | None (storage only) | Direct save. Embedding generated in background. |
| `/index-code <path>` | Claude generates prose | Claude writes prose summary, Python stores pair. Embedding in background. |
| `/forget <id\|query>` | None | Archive/remove memory |
| `/consolidate` | Claude judges | Manual merge trigger. Claude decides which to merge. |

## Memory Lifecycle

### Confidence Decay

| Memory type | Half-life | Rationale |
|------------|-----------|-----------|
| architecture | Stable | Rarely changes |
| decision | Stable | Historical record |
| pattern | 60 days | Evolves over time |
| gotcha | 45 days | May get fixed |
| progress | 7 days | Ephemeral |
| context | 30 days | Session-specific |
| code_description | Stable | Tied to actual code |

Formula: `confidence = initial_confidence * (0.5 ^ (days_since_update / half_life))`

Decay modifiers:
- `pinned = true` → no decay
- `access_count > 10` → half-life doubled
- Centrality > 0.5 → half-life doubled

### Status Transitions

```
active → (confidence < 0.3 for 14d) → archived
active → (human supersedes) → superseded
archived → (accessed via /recall) → active (restored)
archived → (30d untouched) → pruned (deleted)
```

**Supersession is human-only.** LLM consolidation can merge content and archive old memories, but never auto-supersede. This prevents accidental destruction of important memories.

### Consolidation

Triggers: every 10 extractions, >80 active memories, or explicit `/consolidate`.

Process:
1. Checkpoint current DB state
2. Group memories by type + high similarity (>0.5 cosine)
3. Send groups to Haiku: "merge if redundant, preserve unique details"
4. New merged memory = active, old memories = archived (not deleted)

## CLAUDE.md Consciousness Generation

Runs in Stop hook after extraction. Pure algorithm, no LLM.

### Line Budget (~150 lines)

| Category | Lines |
|----------|-------|
| architecture | 25 |
| decision | 25 |
| pattern | 25 |
| gotcha | 20 |
| progress | 30 |
| context | 15 |
| code_description | 10 |

### Ranking Formula

```
rank = (confidence * 0.5) + (priority/10 * 0.2) + (centrality * 0.15) + (log(access_count+1)/max_log * 0.15)
```

### Output

Inserted between markers in project CLAUDE.md:
```markdown
<!-- CORTEX:START -->
## Project Memory

### Architecture
- [ranked memory summaries]

### Decisions
- [...]

### Gotchas
- [...]
<!-- CORTEX:END -->
```

Markers ensure only the memory section is replaced. Hand-written CLAUDE.md content is preserved.

## Auto-Linking (Graph Edges)

At extraction time, each new memory is compared against existing memories:

| Similarity | Action |
|-----------|--------|
| < 0.1 | No relation (orthogonal) |
| 0.1 - 0.5 | Create `relates_to` edge |
| > 0.5 | Flag for consolidation/merge |

Edge type classification via Haiku in a single batch call (one inference for N pairs). Haiku is forbidden from outputting `supersedes` — redirected to `contradicts` if attempted.

### Edge Vocabulary

| Type | Direction | Semantics |
|------|-----------|-----------|
| relates_to | Bidirectional | General association |
| derived_from | Directional | Built from another |
| contradicts | Bidirectional | In tension |
| exemplifies | Directional | Specific instance of concept |
| refines | Directional | More precise version |
| supersedes | Directional | Replacement (human-only) |
| source_of | Directional | Prose → raw code link |

## Plugin Structure

```
cortex/
├── plugin.json                  # Plugin manifest
├── hooks/
│   └── Stop/
│       └── extract-memories.sh  # Bash wrapper → python3 -m cortex extract
├── skills/
│   ├── recall.md                # /recall <query>
│   ├── remember.md              # /remember <text>
│   ├── index-code.md            # /index-code <path>
│   ├── forget.md                # /forget <id|query>
│   └── consolidate.md           # /consolidate
├── agents/
│   └── memory-extractor.md      # Agent for subagent invocation
├── engine/
│   ├── pyproject.toml           # deps: httpx, click
│   ├── cortex/
│   │   ├── __main__.py          # CLI entrypoint
│   │   ├── cli.py               # click commands
│   │   ├── db.py                # SQLite schema, migrations, WAL
│   │   ├── models.py            # Memory, Edge, Extraction dataclasses
│   │   ├── extraction.py        # Transcript → Haiku → memories
│   │   ├── embeddings.py        # Haiku embeddings + cosine similarity
│   │   ├── graph.py             # Edges, BFS traversal, centrality
│   │   ├── lifecycle.py         # Decay, consolidation, pruning
│   │   ├── consciousness.py     # CLAUDE.md generation
│   │   ├── git_context.py       # Branch, commits, changed files
│   │   └── config.py            # API key, paths, thresholds
│   └── tests/
│       ├── test_extraction.py
│       ├── test_graph.py
│       ├── test_lifecycle.py
│       └── test_consciousness.py
└── README.md
```

## Implementation Phases

### Phase 1 — Foundation (DB + extraction + consciousness)

1. **Python engine scaffold** — pyproject.toml, click CLI, config (API key, DB paths)
2. **SQLite schema** — memories, edges, extractions tables. WAL mode. Migrations.
3. **Extraction pipeline** — git_context.py gathers branch/commits/files → extraction.py sends transcript + context to Haiku → parses structured output → stores memories
4. **Embedding generation** — embeddings.py calls Haiku, stores BLOB in SQLite
5. **Consciousness generation** — consciousness.py ranks memories, generates CLAUDE.md section between markers
6. **Stop hook** — extract-memories.sh invokes `python3 -m cortex extract` then `python3 -m cortex generate`
7. **Tests** — extraction parsing, consciousness ranking, embedding cosine similarity

### Phase 2 — Skills + Graph

8. **`/recall` skill** — skill markdown + `cortex recall` CLI command. SQLite candidate retrieval, returns to Claude for ranking.
9. **`/remember` skill** — direct memory creation, queues embedding for background generation
10. **Auto-linking** — at extraction time, compare embeddings, create edges. Batch Haiku call for edge type classification.
11. **Graph module** — BFS traversal, in-degree centrality computation. Centrality feeds into ranking formula.
12. **`/forget` skill** — archive by ID or fuzzy match
13. **Tests** — graph traversal, auto-linking thresholds, recall end-to-end

### Phase 3 — Code Indexing + Lifecycle

14. **`/index-code` skill** — skill markdown instructs Claude to generate prose. `cortex index` CLI stores prose + raw code as linked pair with `source_of` edge.
15. **Lifecycle engine** — decay calculation, status transitions, pruning. Runs as part of Stop hook after extraction.
16. **Consolidation** — `cortex consolidate` CLI. Checkpoint DB, group similar, send to Haiku, merge, archive old.
17. **`/consolidate` skill** — manual trigger, Claude reviews merge proposals
18. **Global memory layer** — separate cortex-global.db, `/recall` searches both DBs, extraction tags global vs project
19. **Tests** — code indexing pairs, lifecycle decay math, consolidation merge logic

### Phase 4 — Polish

20. **Pre-consolidation checkpoints** — snapshot DB before destructive ops
21. **Provenance tracking** — source_type, source_session, source_context populated throughout
22. **Access tracking** — update access_count/last_accessed_at on recall, feed into decay modifiers
23. **Pinning** — `/pin <id>` in /remember skill, skip decay/consolidation
24. **Error logging** — `.memory/cortex.log` with timestamps, silent to Claude
25. **Plugin packaging** — plugin.json manifest, install instructions, README

## v2 Ideas (Deferred)

- **Session-adaptive consciousness** — detect branch/cwd at session start, cache specialized CLAUDE.md surfaces. Exact-match cache for known contexts, fallback to generic ranking.
- **Cross-instance handoff** — if using Claude Desktop + Claude Code, async message-passing between instances via shared DB.
- **Proactive tool docstrings** — engineer skill descriptions to make Claude use memory reflexively ("USE AS REFLEX, NOT OPTION").
- **Embedding metadata injection** — prefix embedding text with `[type] [project:X]` for natural vector space clustering.
- **Hot/cold memory tiers** — explicit tiering instead of relying on ranking alone.
- **Batch operations** — `/index-code` on entire codebase, `/export` memories as markdown, `/import` from another project.

## Configuration

```python
# ~/.config/cortex/config.toml (or env vars)
[api]
anthropic_api_key = "sk-ant-..."  # or ANTHROPIC_API_KEY env var
model = "claude-haiku-4-2025-04-16"  # cheapest for background ops

[paths]
project_db = ".memory/cortex.db"
global_db = "~/.claude/memory/cortex-global.db"
log_file = ".memory/cortex.log"

[extraction]
max_transcript_chars = 65000
cursor_tracking = true

[consciousness]
total_lines = 150
marker_start = "<!-- CORTEX:START -->"
marker_end = "<!-- CORTEX:END -->"

[lifecycle]
consolidation_trigger_count = 10
consolidation_trigger_active = 80
archive_confidence_threshold = 0.3
archive_grace_days = 14
prune_after_days = 30

[graph]
auto_link_threshold = 0.1
consolidation_threshold = 0.5
```

## Unresolved Questions

- Haiku embedding dimensions? Need to verify Haiku can generate embeddings or if we need a separate embedding model (voyage-3-lite via Anthropic API).
- Stop hook: does Claude Code pass transcript via stdin or do we read from a file/API?
- Plugin install: can plugins bundle Python packages, or does the user need to `pip install` separately?
- Global memory: what qualifies as "global" vs "project"? Extraction prompt needs clear instructions for tagging.
- CLAUDE.md location: append to existing project CLAUDE.md or generate a separate `.claude/memory.md` that's auto-included?
