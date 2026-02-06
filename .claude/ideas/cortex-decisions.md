# Cortex — Resolved Design Decisions

Decisions made during loom session 2026-02-06. Use as input to specify phase.

## Final Decisions

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Architecture | Native Claude Code plugin | Hooks, skills, agents. No separate MCP server. |
| 2 | Engine language | **TypeScript** (compiled to JS) | Bundled in plugin via `${CLAUDE_PLUGIN_ROOT}`. No pip install. Node already required by Claude Code. better-sqlite3 for DB. |
| 3 | Storage | SQLite via better-sqlite3 | WAL mode. BLOB for embeddings. FTS5 for text search. |
| 4 | Embeddings | **Voyage AI** (voyage-3.5-lite) | Anthropic's official partner. 200M tokens free tier. ~$0.02/M after. Haiku can't generate embeddings. |
| 5 | Background LLM | Haiku API | Extraction, auto-linking, consolidation. ~$0.02-0.05/day. |
| 6 | Interactive LLM | Claude itself (subscription) | /recall ranking, /index-code prose generation run as skills inside Claude Code. |
| 7 | Push mechanism | `.claude/cortex-memory.local.md` | Auto-loaded by Claude Code at session start. Auto-gitignored. Regenerated between markers by Stop hook. |
| 8 | Pull mechanism | Skills (/recall, /remember, etc) | Native to Claude Code plugin system. No MCP tools needed. |
| 9 | Scope | **Both project + global from v1** | `.memory/cortex.db` per project + `~/.claude/memory/cortex-global.db` for cross-project knowledge. |
| 10 | Code indexing | Prose-code pairing | Claude generates prose, Voyage embeds it, raw code stored separately, linked via `source_of` edge. |
| 11 | Stop hook input | JSON on stdin with `transcript_path` | Must parse JSONL transcript file manually. Also gets `session_id`, `cwd`. |
| 12 | Plugin data storage | `.memory/` per project | cortex.db lives here. Global DB at `~/.claude/memory/cortex-global.db`. |

## Key Technical Findings

- **Haiku can't generate embeddings** — Anthropic doesn't offer embedding models. Voyage AI is the partner.
- **Stop hook** receives JSON on stdin: `{ session_id, transcript_path, cwd, ... }`. Transcript is a JSONL file at `transcript_path`.
- **Plugins can't bundle deps** — but TS compiled to JS + better-sqlite3 (native addon) bundled in plugin dir works. Hooks call via `node ${CLAUDE_PLUGIN_ROOT}/engine/dist/cli.js`.
- **Subagents bypass PreToolUse hooks** — this is by design (block-direct-edits.sh line 8). Subagents CAN use Edit/Write.
- **`.claude/*.local.md`** files are auto-loaded by Claude Code and auto-gitignored.

## Loom Bugs Fixed This Session

1. **advance-phase.sh** — now validates `spec_file` path contains `.claude/specs/`. Previously accepted any existing file path, causing false phase advancement.
2. **All phase templates** — added explicit "You CAN write files" + "Do NOT read .claude/hooks/" instructions to prevent subagents from falsely assuming they're blocked.
