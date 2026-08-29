# Attended benchmark operation in tmux

This procedure is outside the frozen protocol. It standardises operator input
and artifact capture without changing what the model sees.

## 1. Configure tmux once

Pi recommends tmux 3.5+ with CSI-u key reporting:

```tmux
set -g extended-keys on
set -g extended-keys-format csi-u
```

A configuration change requires a full tmux-server restart. Do not restart the
server during a run.

```bash
tmux -V
tmux show-options -g extended-keys
tmux show-options -g extended-keys-format
```

If extended keys are off, modified Enter keys may collapse to plain Enter and
`End` is not a reliable way to choose the final item in a modal. Use counted
arrow-key navigation.

## 2. Create a named session

After `run-arm.sh` prints the worktree, model selector, and run directory:

```bash
SESSION="loom-<arm>-<repetition>"
tmux new-session -d -s "$SESSION" -c '<worktree>' \
tmux send-keys -t "$SESSION" -l -- 'pi --model <exact-selector>'
tmux send-keys -t "$SESSION" Enter
tmux attach-session -t "$SESSION"
```

Keep a second terminal for observation and capture. Never run another arm in
parallel; port 8000 and Cortex isolation are batch-wide resources.

## 3. Submit the task exactly

Use the single-line command printed by `run-arm.sh`. Literal insertion avoids
shell quoting and multiline-paste surprises:

```bash
tmux send-keys -t "$SESSION" -l -- '/loom Read /tmp/task-brief.md and carry out the task it describes.'
tmux send-keys -t "$SESSION" Enter
```

The first model action must read the task file and discuss the JSONL relay core.
If it plans another project, abort and invalidate the run; do not steer it back
onto the benchmark after it has already reasoned over the wrong task.

## 4. Observe without guessing

Capture enough scrollback to include modal headings and recent tool results:

```bash
tmux capture-pane -p -t "$SESSION" -S -3000 > /tmp/"$SESSION".pane.txt
tail -n 120 /tmp/"$SESSION".pane.txt
```

A capture can show stale scrollback while the child is still running. Before
answering, confirm the bottom of a fresh capture contains an active prompt.
Also inspect process and runtime state when progress is ambiguous:

```bash
tmux list-panes -t "$SESSION" -F '#{pane_pid} #{pane_current_command} #{pane_dead}'
pgrep -a -P "$(tmux display-message -p -t "$SESSION" '#{pane_pid}')"
```

Do not infer a timeout from an unchanged pane alone.

## 5. Answer interviews deterministically

Answer only from the protocol-specific answer-key path printed by
`run-arm.sh` (`protocols/v2/frozen/answer-key.md` for default v2) and append
every question and exact answer to the run’s `interview.md`.

For free-text prompts, insert the exact answer literally, then submit once:

```bash
ANSWER='Use your judgement and record the decision in the spec.'
tmux send-keys -t "$SESSION" -l -- "$ANSWER"
tmux send-keys -t "$SESSION" Enter
```

For selection modals:

1. capture the pane and count the target row;
2. send the required number of `Down` keys;
3. capture again and verify the highlighted row;
4. send one `Enter`.

To enter a scripted free-text answer through a menu, navigate to **Type a
different answer…** using counted `Down` keys. Do not use `End` when extended
keys are disabled.

Pi queue semantics matter while a child is busy:

- `Enter` queues steering for the next turn;
- `Alt+Enter` queues a follow-up after all current work;
- `Escape` aborts and restores queued messages to the editor;
- `Alt+Up` retrieves a queued message.

Do not submit an interview answer as a steering message before the modal is
visible.

## 6. Stop at the planning boundary

The model-visible brief requires it to stop after decomposition. The valid
terminal graph is:

```text
current_phase = execute
current_wave = 1
all task.status = pending
executing_tasks = []
all wave gates untouched
```

`execute` here means “ready to execute,” not “implementation authorized.” When
the parent reports decomposition complete, inspect the graph before sending any
further input:

```bash
jq '{current_phase,current_wave,statuses:[.tasks[].status],executing_tasks,wave_gates}' \
  '<worktree>/.claude/state/active_task_graph.json'
```

If all tasks are pending, stop Pi cleanly with `/quit` or two `Ctrl+C` presses.
Do not approve, continue, or steer into Wave 1. If any task is running or
complete, terminate immediately and preserve the run as an invalid
stop-boundary result.

## 7. Capture the session

Pi stores sessions under `~/.pi/agent/sessions/` by working directory. The
reliable source is `/session` while Pi is open; it prints the current session
file. Record that path before quitting when possible.

If it was not recorded, locate recent JSONL files and verify the worktree/task
inside the candidate rather than choosing solely by timestamp:

```bash
find ~/.pi/agent/sessions -type f -name '*.jsonl' -mmin -360 -printf '%T@ %p\n' \
  | sort -nr | head -20
rg -l 'task-brief.md|ui-relay' ~/.pi/agent/sessions --glob '*.jsonl'
```

Then preserve it:

```bash
cp '<session-file>.jsonl' '<run-dir>/session.jsonl'
grep -n 'CORTEX_MEMORY_START' '<run-dir>/session.jsonl'  # any match voids
bash benchmarks/loom-model-ab/scripts/verify-run-models.sh '<run-dir>'
bash benchmarks/loom-model-ab/scripts/grade-planning.sh '<worktree>' '<run-dir>'
```

The grader copies the model-authored planning artifacts from the active graph.
`interview.md` and `session.jsonl` must already exist.

## 8. Preserve first, clean up second

Only after `outcome.planning.json`, the discovery worksheet, artifacts, and
transcript exist:

```bash
tmux kill-session -t "$SESSION" 2>/dev/null || true
git -C ~/dev/claude-plugins/loom worktree remove '<worktree>'
```

Restore Cortex only after the final repetition in the batch.
