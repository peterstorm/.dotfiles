# Async Session Loading with Loading State

## Context
`list_sessions()` reads+deserializes **full** `SessionArchive` files (events, agents, task_graph) at startup via `load_existing_files()`. The sessions view only needs `SessionMeta` for the table. With many/large archives this blocks the TUI from rendering.

## Root Cause
`session::list_sessions()` calls `load_session()` per file which deserializes full JSON archives. This runs synchronously on the watcher thread at startup. Even the sessions *list* view only uses `archive.meta`.

## Fix

### 1. New `list_session_metas()` — meta-only loading (`session/mod.rs`)
- Add `fn list_session_metas(dir) -> Result<Vec<(PathBuf, SessionMeta)>, String>`
- Reads each JSON file, deserializes only the `"meta"` field via a helper struct: `struct MetaOnly { meta: SessionMeta }`
- Returns `(path, meta)` tuples so we can load full archive later by path
- Much faster: skips deserializing events/agents/task_graph

### 2. State: store lightweight session index (`state.rs`)
- Replace `sessions: Vec<SessionArchive>` with `sessions: Vec<ArchivedSession>`
- New struct:
  ```rust
  pub struct ArchivedSession {
      pub meta: SessionMeta,
      pub path: PathBuf,
      pub data: Option<SessionArchive>,  // None = not loaded yet
  }
  ```
- Sessions list uses `meta` directly (always available)
- Session detail uses `data` (loaded on demand)

### 3. New `AppEvent::SessionMetasLoaded` (`event/mod.rs`)
- `SessionMetasLoaded(Vec<(PathBuf, SessionMeta)>)` — replaces `SessionListRefreshed` for startup
- Keep `SessionListRefreshed(Vec<SessionArchive>)` for full-load path (backward compat)

### 4. Update handler for `SessionMetasLoaded` (`update.rs`)
- Maps `(path, meta)` pairs into `ArchivedSession { meta, path, data: None }`
- Sets `state.sessions`

### 5. Async full-archive loading on Enter (`navigation.rs` + `main.rs`)
- When user presses Enter on a session in Sessions view:
  - If `data.is_some()` → navigate to SessionDetail immediately
  - If `data.is_none()` → set `state.loading_session = Some(idx)`, emit `AppEvent::LoadSessionRequested(idx)`
- In main event loop or watcher: spawn background load, send `SessionLoaded` on completion
- `SessionLoaded` handler: populate `sessions[idx].data = Some(archive)`, clear loading flag, navigate to detail

### 6. Loading indicator in sessions view (`sessions.rs`)
- If `state.loading_session == Some(idx)` → show "Loading..." spinner/text on that row
- Or render a centered loading overlay on the content area

### 7. Watcher: use `list_session_metas` at startup (`watcher/mod.rs`)
- Replace `session::list_sessions(&paths.archive_dir)` with `session::list_session_metas(&paths.archive_dir)`
- Send `SessionMetasLoaded` instead of `SessionListRefreshed`

### 8. Session detail: handle unloaded state (`session_detail.rs`)
- `get_selected_session_data` for archived sessions: check `sessions[idx].data`
- If `None` → return special "loading" variant or `None` (render loading screen)

### 9. Adapt existing `SessionLoaded` handler (`update.rs`)
- When `SessionLoaded(archive)` arrives, find matching session in `state.sessions` by meta.id
- Set `data = Some(archive)`, clear `loading_session`
- Navigate to `SessionDetail`

### 10. Tests
- `list_session_metas` returns correct meta + path pairs
- `ArchivedSession` with `data: None` renders in session list
- Enter on unloaded session sets loading state
- `SessionLoaded` populates data and navigates

## File summary
| File | Change |
|------|--------|
| `src/model/session.rs` | Add `ArchivedSession` struct |
| `src/session/mod.rs` | Add `list_session_metas()` |
| `src/event/mod.rs` | Add `SessionMetasLoaded` variant |
| `src/app/state.rs` | `sessions: Vec<ArchivedSession>`, `loading_session: Option<usize>` |
| `src/app/update.rs` | Handle `SessionMetasLoaded`, adapt `SessionLoaded` |
| `src/app/navigation.rs` | Enter triggers load-or-navigate |
| `src/view/sessions.rs` | Use `ArchivedSession.meta`, show loading row |
| `src/view/session_detail.rs` | Handle unloaded data |
| `src/watcher/mod.rs` | Use `list_session_metas` at startup |
| Tests | New + adapted tests |

## Verification
1. `cargo build` — clean compile
2. `cargo test` — all pass
3. Run TUI with many archived sessions — instant Sessions view, detail loads on Enter
