# Show assistant reasoning in activity stream

## Context
Activity stream only shows tool use events from hooks. The actual reasoning/thinking text lives in Claude Code transcript files (`~/.claude/projects/<hash>/<session-id>.jsonl`). User wants to see what agents are thinking inline with tool events.

## Data source
Claude Code transcript JSONL has `type: "assistant"` entries with `.message.content[]` blocks:
- `type: "text"` — visible reasoning (what agent says before/after tool use)
- `type: "thinking"` — extended thinking (internal chain of thought)

Each entry has `sessionId`, `timestamp`, `cwd`. The `transcript_path` field is sent in all hook events including SessionStart.

## Approach

### 1. Capture `transcript_path` in hook script + store per session

**`~/.claude/hooks/send_event.sh`** — extract `transcript_path` from hook JSON, include in `session_start` event (alongside existing `cwd`)

**`src/model/session.rs`** — add `transcript_path: Option<String>` to `SessionMeta`

**`src/app/update.rs`** — on `SessionStart`, extract `transcript_path` from `event.raw` and store in session meta

### 2. Add new HookEventKind variant

**`src/model/hook_event.rs`** — add:
```rust
HookEventKind::AssistantText { content: String }
```

Constructor: `HookEventKind::assistant_text(content)`. Also add to `parse_hook_events` (event tag: `"assistant_text"`).

### 3. Tail transcript files, emit assistant text events

**`src/watcher/parsers.rs`** — add:
```rust
pub fn parse_claude_transcript_incremental(content: &str, byte_offset: usize) -> Vec<HookEvent>
```
Pure function. Reads JSONL from `byte_offset`, extracts `assistant` entries, returns `HookEvent` with `AssistantText` kind, `session_id`, and `timestamp`.

Only extracts `text` blocks (visible reasoning). Skips `thinking` blocks (too verbose, internal). Truncates content to 500 chars per block.

**`src/watcher/mod.rs`** — new function `poll_transcripts()`:
- Runs on same 200ms polling loop as events
- Iterates `state.active_sessions` to get `transcript_path` values
- Uses `TailState` to track byte offset per transcript file
- Calls `parse_claude_transcript_incremental()` on new content
- Emits `AppEvent::HookEventReceived` for each extracted message

Discovery: pass active session transcript paths from main loop to watcher thread via a shared `Arc<Mutex<Vec<(String, PathBuf)>>>` (session_id → transcript_path pairs).

### 4. Render in event stream

**`src/view/components/event_stream.rs`** — extend `format_event_lines()`:
```rust
HookEventKind::AssistantText { content } => {
    ("💭", "Thinking".into(), Some(content.clone()), Theme::MUTED_TEXT, None)
}
```

Uses existing detail rendering (word wrap, clean_detail). Shows inline with tool events, sorted by timestamp.

### 5. Wire transcript paths from state to watcher

**`src/main.rs`** — share `Arc<Mutex<BTreeMap<String, String>>>` between main loop and watcher. On each tick or SessionStart, update the map with `session_id → transcript_path`. Watcher reads from this map.

Alternative simpler approach: have `update()` emit `AppEvent::WatchTranscript(session_id, path)` which the main loop forwards to the watcher. But this requires a second channel. The shared map is simpler.

## File summary
| File | Change |
|------|--------|
| `~/.claude/hooks/send_event.sh` | Add `transcript_path` to session_start event |
| `src/model/session.rs` | Add `transcript_path: Option<String>` to SessionMeta |
| `src/model/hook_event.rs` | Add `AssistantText { content }` variant + constructor |
| `src/watcher/parsers.rs` | Add `parse_claude_transcript_incremental()` |
| `src/watcher/mod.rs` | Add transcript polling, shared path map |
| `src/app/update.rs` | Extract transcript_path on SessionStart |
| `src/view/components/event_stream.rs` | Render AssistantText in format_event_lines |
| `src/main.rs` | Wire shared transcript path map between state + watcher |

## Verification
1. `cargo build` — clean compile
2. `cargo test` — all pass
3. Run TUI with active Claude Code session — reasoning text appears inline in activity stream between tool events
