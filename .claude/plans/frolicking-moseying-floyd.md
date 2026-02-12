# Agent List View Refactor

## Context
AgentDetail view currently shows tool_call_list + reasoning_panel from `agent.messages`, but no transcript data is ever available so both panels are always empty. Replace with: left = selectable agent list, right = hook events filtered to selected agent.

## Files to modify
- `src/app/state.rs` — ViewState, AppState, ScrollState
- `src/app/navigation.rs` — scroll/select/switch logic
- `src/view/mod.rs` — dispatch
- `src/view/agent_detail.rs` — full rewrite
- `src/view/components/event_stream.rs` — add filtered variant
- `src/view/components/mod.rs` — swap exports
- `tests/navigation_tests.rs` — update all AgentDetail refs
- `tests/view_tests.rs` — update AgentDetail refs

## Files to delete
- `src/view/components/tool_call_list.rs`
- `src/view/components/reasoning_panel.rs`

## New file
- `src/view/components/agent_list.rs`

---

## Steps

### 1. State changes (`state.rs`)

**ViewState**: `AgentDetail { agent_id: String }` → `AgentDetail` (no payload)

**AppState**: add `selected_agent_index: Option<usize>` (consistent w/ `selected_task_index` pattern). Init to `None`.

**ScrollState**: rename `tool_calls` → `agent_list`, `reasoning` → `agent_events`. Update `reset()`.

### 2. Navigation (`navigation.rs`)

**`switch_to_agent_detail`**: simplify — just set `ViewState::AgentDetail`, auto-select first agent if `selected_agent_index` is None and agents exist.

**`scroll_down/scroll_up` for AgentDetail**:
- Left panel: move `selected_agent_index` (clamped 0..agents.len()-1), reset `agent_events` scroll on change
- Right panel: scroll `agent_events` offset, disable `auto_scroll`

**`drill_down` from Dashboard**: set `ViewState::AgentDetail`, find agent's position in BTreeMap keys for `selected_agent_index`.

**`go_back`**: update match arm from `AgentDetail { .. }` to `AgentDetail`.

### 3. View dispatch (`view/mod.rs`)

Change match arm signature, drop `agent_id` param from `render_agent_detail`.

### 4. New `agent_list` component

Render `state.agents.values()` as list items:
- `◐` active (green), `●` finished (dim)
- `agent.display_name()` + elapsed duration
- Highlight `selected_agent_index` row
- Border color based on focus

### 5. Filtered event stream (`event_stream.rs`)

Refactor `build_event_stream_lines` to accept `Option<&str>` agent filter. Add `render_agent_event_stream(frame, area, state, agent_id, scroll_offset, is_focused)`.

### 6. Rewrite `agent_detail.rs`

Layout: `[header(3)][main(min)][footer(1)]`, main split `[agent_list(30%)][agent_events(70%)]`. Derive selected agent from `selected_agent_index` + BTreeMap keys. Header shows selected agent info.

### 7. Remove old components

Delete `tool_call_list.rs`, `reasoning_panel.rs`. Update `components/mod.rs`.

### 8. Fix all tests

All `ViewState::AgentDetail { agent_id: ... }` → `ViewState::AgentDetail`. Scroll tests update field names. Add agent selection tests.

### 9. Verify

`cargo test && cargo clippy`

---

## Unresolved
- Keep `agent.messages` accumulation in `update.rs`? (recommend yes, cheap, useful later)
