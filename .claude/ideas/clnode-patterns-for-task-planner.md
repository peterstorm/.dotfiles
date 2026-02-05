# clnode Patterns for Task-Planner

Analysis of [SierraDevsec/clnode](https://github.com/SierraDevsec/clnode) — a Claude Code swarm intelligence plugin — and how its patterns apply to our existing task-planner orchestration system.

## What clnode Is

A hook-based plugin that adds **agent-to-agent communication** via shared memory (DuckDB). Solves "agents can't see each other's work" — one agent's output becomes available to subsequent agents through a database layer, keeping the Leader agent lean.

**Tech stack**: Node.js 22, TypeScript, Hono, DuckDB, React 19 + TailwindCSS 4 (web UI on :3100).

**Hook integration points**:
- `SubagentStart` — inject prior agent context
- `SubagentStop` — save compressed work summaries
- `PostToolUse` — track file modifications
- `UserPromptSubmit` — auto-attach project context

**Key features**:
- Smart context injection (sibling summaries, same-role history, cross-session, tagged entries)
- 97% compression via dedicated skill (31K → ~2K chars)
- 6-stage Kanban with automatic status transitions
- Model allocation recommendations (Opus=leader, Sonnet=impl, Haiku=routine)

## Two Distinct Problems

clnode and the memory-mcp-fork solve **different axes** of the same meta-problem ("agents lack context"):

| Axis | Problem | Solution |
|------|---------|----------|
| **Intra-session** | Agents within a task-planner run can't see siblings' work | clnode's shared memory pattern |
| **Cross-session** | Each `/task-planner` invocation starts fresh, no learning | memory-mcp-fork's persistent memory |

Our task-planner currently has **neither**.

## Current Task-Planner Gaps (clnode-relevant)

### Gap 1: No Work Summaries

`update-task-status.sh` extracts:
- `tests_passed` + `test_evidence`
- `files_modified` (from Write/Edit tool calls)
- `new_tests_written` + `new_test_evidence`

But does NOT store **what the agent actually did** — the architectural decisions made, interfaces created, patterns established. Wave 2 agents are blind to Wave 1's actual work beyond file lists.

### Gap 2: No Context Injection

`mark-subagent-active.sh` stores metadata (agent type, task ID, session path) but **injects nothing** into the agent's prompt. Each agent starts with only its task description from the task graph.

clnode's SubagentStart injects:
- Sibling agent summaries (same wave)
- Same-role history (prior agents of same type)
- Cross-session relevant data
- Tagged context entries

### Gap 3: No Compression

Agent transcripts can be 30K+ chars. Without compression, storing full output in task graph is impractical. clnode achieves 97% compression via Haiku, making it feasible to store and inject work context.

## Stealable Patterns

### Pattern 1: Compressed Work Summaries (HIGH VALUE)

**What**: On SubagentStop, compress agent's work into ~2K summary and store in task graph.

**Where**: Enhance `update-task-status.sh` (or add new hook `extract-work-summary.sh`).

**How**:
```bash
# In SubagentStop hook, after existing evidence extraction:
# 1. Extract agent transcript (already available as $TRANSCRIPT)
# 2. Call Haiku for compression
# 3. Store in task graph as work_summary field

# New field in task graph per-task:
{
  "work_summary": "Created OrderService with wave-based processing. Defined sealed interface PaymentResult (Success|Failed|Pending). Added /api/orders POST endpoint with Zod validation. Key decision: used Zustand over Redux for state. Modified: OrderService.ts, PaymentResult.ts, orders/route.ts",
  "interfaces_created": ["PaymentResult", "OrderRequest", "OrderResponse"],
  "key_decisions": ["Zustand over Redux", "sealed interface for payment states"]
}
```

**Cost**: ~$0.001/agent via Haiku. Negligible for typical 5-15 agent runs.

**Why not just store files_modified?** File lists tell you *where* changes happened, not *what* or *why*. Agent B needs to know "Agent A created a PaymentResult sealed interface with 3 variants" — not just "Agent A modified PaymentResult.ts".

### Pattern 2: Context Injection at SubagentStart (HIGH VALUE)

**What**: Before an agent starts, inject compressed summaries from completed tasks.

**Where**: Enhance `mark-subagent-active.sh` to also inject context.

**How**:
```bash
# In SubagentStart hook:
# 1. Read task graph
# 2. Find completed tasks (prior waves + completed same-wave siblings)
# 3. Build context block from work_summaries
# 4. Inject as system message / prepended context

# Context template:
"## Prior Agent Work (DO NOT repeat this work)
### Wave 1 - Completed
- Task 1 (code-implementer): ${work_summary_1}
- Task 2 (java-test-agent): ${work_summary_2}

### Wave 2 - In Progress (siblings)
- Task 3 (frontend-agent): ${work_summary_3}  # if already completed

### Key Interfaces & Decisions
- PaymentResult: sealed interface (Success|Failed|Pending)
- State management: Zustand (decided in Task 1)
"
```

**Injection strategies**:
- **All prior waves**: Always inject. Cheap after compression.
- **Same-wave siblings**: Only inject if already completed (race-safe since hooks are sequential per agent).
- **Relevance filtering**: Optional. Could skip unrelated tasks (e.g., k8s-agent summary irrelevant to frontend-agent). But wave-order already implies relevance — simpler to inject all.

### Pattern 3: Compression Skill (MEDIUM VALUE)

**What**: Dedicated skill/helper for compressing agent output into structured summaries.

**Why separate**: Reusable across hooks. Consistent format. Can be improved independently.

**Format**:
```
SUMMARY: 1-2 sentence overview
CREATED: list of new files/types/interfaces
MODIFIED: list of changed files with what changed
DECISIONS: key architectural/design decisions made
DEPENDENCIES: what this task depends on or creates for others
PATTERNS: reusable patterns established
```

**Implementation options**:
1. **Inline in hook** — simplest, call Haiku via `claude --model haiku -p "compress this..."`
2. **Separate script** — `compress-agent-output.sh` called by hook
3. **Claude Code skill** — most structured, but skills run in main agent context

Recommend option 2 for now. Can promote to skill later.

### Pattern 4: PostToolUse File Tracking (ALREADY COVERED)

clnode tracks file modifications via PostToolUse hook. Our `update-task-status.sh` already extracts files from Write/Edit tool calls in SubagentStop. **No action needed.**

## Patterns NOT Worth Adopting

### DuckDB Persistence

clnode uses DuckDB for structured queries across agent data. Our `active_task_graph.json` + jq is sufficient for intra-session communication. Adding DuckDB means:
- New dependency (Node.js + DuckDB binary)
- Migration path for existing hooks (all bash/jq)
- Complexity for ~5-15 agents per run

**Verdict**: Not worth it. JSON + jq scales fine for task-planner's scope. If we hit 50+ agents per run, revisit.

### Web UI Dashboard

clnode has a React UI on :3100 showing real-time agent hierarchy, search, activity logs via WebSocket. Our GitHub Issue with auto-updating checkboxes is:
- Already integrated
- Persistent (survives session end)
- Accessible from anywhere
- Zero maintenance

**Verdict**: Skip. GH Issue is the better UX for our workflow.

### 6-Stage Kanban

clnode's `idea → planned → active → review → completed → archived`. Our status machine is `pending → in_progress → implemented → completed` with wave gates enforcing quality between `implemented` and `completed`.

**Verdict**: Our model is more rigorous (wave gates > kanban columns). No change needed.

### Model Allocation Recommendations

clnode suggests Opus for leaders, Sonnet for implementation, Haiku for routine. Our task-planner already assigns models per agent type in the skill definition.

**Verdict**: Already handled.

## Integration with Memory-MCP-Fork

The two initiatives are **complementary and independent**:

```
clnode patterns (Phase 1)     memory-mcp-fork (Phase 2)
─────────────────────────     ────────────────────────
Intra-session communication   Cross-session learning
work_summary in task graph    Persistent state.json + CLAUDE.md
Context injection at start    Session-adaptive consciousness
Compression via Haiku         Geometric dedup + consolidation
```

**Phase 1 enables Phase 2**: Work summaries are the raw material for memory extraction. Once we store structured summaries per-task, the memory system can consume them at SessionEnd to extract long-term learnings.

**Data flow**:
```
Agent completes
  → SubagentStop: compress → work_summary in task graph (Phase 1)
  → SessionEnd: extract learnings from summaries → memory store (Phase 2)
  → Next session: inject relevant memories at SessionStart (Phase 2)
  → SubagentStart: inject work summaries + memories (Phase 1 + 2)
```

## Implementation Plan

### Phase 1: Intra-Session Communication (clnode patterns)

**Step 1**: Add `compress-agent-output.sh` helper
- Input: agent transcript (from SubagentStop)
- Output: structured summary (SUMMARY/CREATED/MODIFIED/DECISIONS/DEPENDENCIES/PATTERNS)
- Uses Haiku for compression (~$0.001/call)
- Falls back to truncated raw output if Haiku unavailable

**Step 2**: Enhance `update-task-status.sh`
- After existing evidence extraction, call compress helper
- Store `work_summary` field in task's entry in task graph
- Store `interfaces_created` and `key_decisions` as structured arrays

**Step 3**: Enhance `mark-subagent-active.sh` → context injection
- Read completed tasks from task graph
- Build context block from work_summaries
- Inject via SubagentStart message prepend
- Include key interfaces and decisions section

**Step 4**: Add `inject-context.sh` helper
- Separate from mark-subagent-active for testability
- Builds context from task graph state
- Configurable: all-waves vs current-wave-only vs relevance-filtered

### Phase 2: Cross-Session Learning (memory-mcp-fork)

See `memory-mcp-fork.md` for full plan. Key integration point: SubagentStop summaries feed memory extraction.

### Phase 3: Compression Skill (optional)

Promote `compress-agent-output.sh` to a dedicated Claude Code skill if the pattern proves valuable. Enables reuse beyond task-planner hooks.

## Cost Analysis

| Operation | Per-Agent Cost | Per-Run (10 agents) |
|-----------|---------------|---------------------|
| Haiku compression | ~$0.001 | ~$0.01 |
| Context injection | $0 (no LLM call, just data assembly) | $0 |
| Memory extraction (Phase 2) | ~$0.001 | ~$0.01 |
| **Total overhead** | **~$0.002** | **~$0.02** |

Negligible compared to Opus/Sonnet agent costs ($0.50-2.00/agent).

## Unresolved Questions

- Store work_summary in task graph JSON or separate `summaries/` dir? JSON simpler but grows file size
- Inject ALL prior summaries or relevance-filter? Wave-order may be sufficient filter
- Compression: inline Haiku call in bash hook or spawn a haiku subagent?
- How to handle compression failure gracefully? (Haiku down, rate limited)
- Should same-wave siblings see each other's summaries? Risk of stale data if agents running in parallel
- Context injection: prepend to SubagentStart message or write to temp file agent reads?
- Max context budget for injected summaries? (2K per task × 15 tasks = 30K — too much?)
- Should we extract `interfaces_created` structurally or leave it in free-text summary?
