# loom-tui: Multi-Agent Observability TUI

Rust TUI dashboard for monitoring Claude Code agent orchestration.
Passive viewer now, orchestration-ready architecture for later.

## Data Sources

### General: Hook Events
Single bash script in `.claude/hooks/` fires on all event types (PreToolUse, PostToolUse, SubagentStart, SubagentStop, Stop, SessionStart, SessionEnd, Notification, UserPromptSubmit). Appends JSON lines to `/tmp/loom-tui/events.jsonl` via `jq`. No server, no HTTP.

### Loom-specific: State Files
File-watch via `notify` (inotify):
- `active_task_graph.json` - task status, waves, phases, test evidence, reviews
- `subagents/agent-*.jsonl` - per-agent tool call transcripts
- `/tmp/claude-subagents/*.active` - active agent markers

Auto-detects loom sessions (presence of task graph). Non-loom sessions get event-stream-only dashboard.

## Architecture

Elm Architecture (Model/Update/View) with functional core, imperative shell.

```
Watchers (notify/tokio) --> Channel --> update(state, event) --> render(&state)
     ^                                        ^                       |
     |                                        |                       v
  File I/O                               Pure function           Ratatui frame
  (imperative shell)                     (functional core)       (pure rendering)
```

### Event Loop
Tokio-based. Three event sources merged into one `mpsc` channel:
- File change events (from notify watchers)
- Keyboard input (from crossterm)
- Tick events (250ms, for animations/elapsed timers)

## Views

### 1. Dashboard (default)

```
+-- loom-tui ---------------------------------------- 3 active -- wave 2/4 -+
| [wave progress river: segmented bar per wave, filled/partial/empty]       |
+-- tasks -----------------------+-- events --------------------------------+
|                                |                                          |
|  W1                            |  14:30:02  Bash     a04  cargo build     |
|  V T1  Auth module             |  14:30:05  Read     b12  src/routes.rs   |
|  V T2  User model              |  14:30:07  Edit     a04  src/routes.rs   |
|                                |  14:30:08  Bash     c33  npm test        |
|  W2                            |  14:30:11  Write    a04  src/models.rs   |
|  > T3  API routes     a04     |  14:30:12  Task     b12  spawn impl      |
|  > T4  Middleware      b12     |  14:30:15  Read     c33  package.json    |
|  > T5  Validators     c33     |                                          |
|                                |                                          |
|  W3                            |                                          |
|  . T6  Integration tests       |                                          |
|  . T7  E2E tests               |                                          |
+--------------------------------+------------------------------------------+
| 1 dashboard  2 agent  3 sessions | /:filter  enter:detail  q:quit         |
+----------------------------------------------------------------------- ---+
```

- Tasks panel: 35% width, grouped by wave
- Events panel: 65% width, live stream with auto-scroll
- Wave progress river: hero element at top
- Status markers: V=done(blue) >=running(green) X=failed(red) .=pending(dim)

### 2. Agent Detail

```
+-- agent-a04 -- T3: API routes ---------------------- active -- 2m 34s ---+
+-- tool calls ----------------------+-- reasoning -------------------------+
|                                    |                                      |
|  14:30:02  Bash                    |  I'll start by reading the           |
|  $ cargo build                     |  existing route handlers...          |
|  +-- exit 0                 1.2s   |                                      |
|                                    |                                      |
|  14:30:07  Edit                    |  The routes use axum's Router        |
|  src/routes.rs  +12 -3             |  with typed extractors...            |
|  +-- applied                       |                                      |
|                                    |                                      |
+------------------------------------+--------------------------------------+
| esc:back  j/k:scroll  f:filter-tools  t:toggle-reasoning  w:wide          |
+----------------------------------------------------------------------  ---+
```

- Tool calls: 55% width, tree-style results with duration
- Reasoning: 45% width, agent text between tool calls
- t: toggle reasoning panel, w: full-width tools, f: filter tool types

### 3. Sessions

Table: session ID, app/type, start time, duration, agent count, event count.
Active session highlighted green. Date separators for grouping.
Enter loads any session into Dashboard view (works for live + historical).

## Color System

```
Background:      #0c0c0c
Surface:         #161616
Border idle:     #2a2a2a
Border focus:    #4a9eff (bright blue)
Text primary:    #c8c8c8
Text dim:        #555555

Status:
  Running:       #4ae04a (green)
  Pending:       #555555 (dim)
  Complete:      #4a9eff (blue)
  Failed:        #e04a4a (red)
  Blocked:       #c8a04a (amber)

Tool types:
  Bash:          #4ae0c8 (teal)
  Read:          #7a9eff (periwinkle)
  Write:         #4ae04a (green)
  Edit:          #c8c04a (gold)
  Grep/Glob:     #9a7aef (violet)
  Task:          #e07a4a (orange)
  WebFetch:      #e04a9a (magenta)

Agent IDs: auto-assigned from 8-hue rotating palette.
```

No emojis. Color and single-character markers only.

## Navigation

| Key | Action |
|-----|--------|
| 1/2/3 | Switch views |
| Tab, h/l | Switch panel focus |
| j/k, arrows | Scroll within panel |
| Enter | Drill into selected item |
| Esc | Back to previous view |
| / | Filter/search popup |
| ? | Help overlay |
| Space | Pause/resume auto-scroll |
| +/- | Density toggle (compact/normal/expanded) |
| t | Toggle reasoning panel (agent view) |
| w | Wide mode for tool calls (agent view) |
| f | Filter tool types (agent view) |
| q | Quit |

## Crate Structure

```
loom-tui/
  src/
    main.rs              # Entry, arg parsing, event loop (imperative shell)
    app.rs               # AppState + update() (functional core)
    event.rs             # AppEvent enum
    watcher/
      task_graph.rs      # Watch + parse active_task_graph.json
      transcripts.rs     # Watch + parse agent-*.jsonl
      hook_events.rs     # Watch /tmp/loom-tui/events.jsonl
      active_agents.rs   # Watch /tmp/claude-subagents/*.active
    model/
      task.rs            # Task, Wave, TaskStatus, ReviewStatus
      agent.rs           # Agent, ToolCall, AgentMessage
      event.rs           # HookEvent (all types)
      session.rs         # Session metadata
    view/
      dashboard.rs       # Dashboard layout
      agent_detail.rs    # Agent drill-down
      sessions.rs        # Session browser
      help_overlay.rs    # ? keybind overlay
      filter_bar.rs      # / search popup
    widgets/
      wave_river.rs      # Wave progress bar
      task_list.rs       # Task panel with wave grouping
      event_stream.rs    # Scrolling event feed
      tool_call_list.rs  # Agent tool call timeline
      reasoning_panel.rs # Agent reasoning text
    theme.rs             # Colors, styles, constants
  hooks/
    send_event.sh        # Universal hook script
```

## Dependencies

- ratatui 0.29 + crossterm 0.28 (TUI)
- tokio (async runtime)
- notify 7 (file system watching)
- serde + serde_json (parsing)
- chrono (timestamps)
- clap 4 (CLI args)
- color-eyre (errors)

## Key Data Types

```rust
enum TaskStatus { Pending, Implemented, Completed, Failed { reason, retry_count } }
enum ReviewStatus { Pending, Passed, Blocked { critical, advisory } }
struct Task { id, description, agent, wave, status, tests_passed, review_status, files_modified }
struct Agent { id, agent_type, task_id, session_id, started_at, finished_at, messages }
enum MessageKind { Reasoning(String), Tool(ToolCall) }
struct ToolCall { timestamp, tool_name, input_summary, result_summary, duration, success }
enum HookEvent { SessionStart, SessionEnd, SubagentStart, SubagentStop, PreToolUse, PostToolUse, Stop, ... }
```

## Unresolved Questions

- Name? `loom-tui`, `agenthud`, `orchestr8`, something else?
- Nix packaging? Flake with `crane` or `naersk` for Rust builds?
- Log rotation for `/tmp/loom-tui/events.jsonl`? Max size before truncation?
- Should sessions view support deleting old session data?
- Config file for customizing colors/keybinds, or hardcoded initially?
