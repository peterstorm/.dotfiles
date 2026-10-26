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

After `run-arm.sh` prints the worktree, model selector, and run directory,
start Pi with the exact launch line it printed, never a hand-written
`pi --model …`. Use a private tmux server (`-L`), so no other session on the
machine can address the run's pane by name:

```bash
T=(tmux -L loom-bench)
SESSION="loom-<arm>-<repetition>"
"${T[@]}" new-session -d -s "$SESSION" -c '<worktree>'
"${T[@]}" send-keys -t "$SESSION" -l -- '<launch line printed by run-arm.sh>'
"${T[@]}" send-keys -t "$SESSION" Enter
"${T[@]}" attach-session -t "$SESSION"
```

Use `"${T[@]}"` for every later tmux command in this runbook. Keep a second
terminal for observation and capture. Never run another arm in parallel; port
8000 and memory isolation are batch-wide resources.

## 3. Submit the task exactly

Use the single-line command printed by `run-arm.sh`. Literal insertion avoids
shell quoting and multiline-paste surprises:

```bash
"${T[@]}" send-keys -t "$SESSION" -l -- '/loom Read /tmp/task-brief.md and carry out the task it describes.'
"${T[@]}" send-keys -t "$SESSION" Enter
```

The first model action must read the task file and discuss the JSONL relay core.
If it plans another project, abort and invalidate the run; do not steer it back
onto the benchmark after it has already reasoned over the wrong task.

## 4. Observe without guessing

Capture enough scrollback to include modal headings and recent tool results:

```bash
"${T[@]}" capture-pane -p -t "$SESSION" -S -3000 > /tmp/"$SESSION".pane.txt
tail -n 120 /tmp/"$SESSION".pane.txt
```

A capture can show stale scrollback while the child is still running. Before
answering, confirm the bottom of a fresh capture contains an active prompt.
Also inspect process and runtime state when progress is ambiguous:

```bash
"${T[@]}" list-panes -t "$SESSION" -F '#{pane_pid} #{pane_current_command} #{pane_dead}'
pgrep -a -P "$("${T[@]}" display-message -p -t "$SESSION" '#{pane_pid}')"
```

Do not infer a timeout from an unchanged pane alone.

## 5. Answer interviews deterministically

Answer only from the run's protocol answer key, and only through
`scripts/interview.sh`. Never type an answer, and never pick one with a
keyword filter. The key is organised by topic while Loom asks specific
questions, and hand-matching drifts both ways: ds41-2 and ds41-3 were voided
for covered questions that got the judgement line, and ds41-3 Q4 got a bare
"No." to a confirm-the-list question.

For every question, copy it exactly as shown (label included) and ask for the
candidates:

```bash
I=(bash benchmarks/loom-model-ab/scripts/interview.sh '<run-dir>')
"${I[@]}" suggest '<question as shown>'
```

- **TAGGED**: the question's parenthetical names an answer-key topic, e.g.
  "(Error-handling philosophy / observability)". The agent filed it under that
  topic, so answer from a tagged topic. `log` refuses the judgement line here.
- **HINTED**: the question mentions a topic's phrases. Read that topic's
  answer and use it only if it genuinely answers the question. A topic that
  merely shares a word does not cover it.
- Otherwise use `judgement`, but only after reading the full listing that
  follows.
- A scripted answer that begins with a bare "No." fits only a yes/no
  question. To a "confirm …" or "which …" question it reads as a refusal, so
  prefer the judgement line unless another topic genuinely covers it.

Then log the exchange and send the exact text it prints, inserting it
literally and submitting once:

```bash
ANSWER="$("${I[@]}" log '<question as shown>' <topic-number|judgement>)"
"${T[@]}" send-keys -t "$SESSION" -l -- "$ANSWER"
"${T[@]}" send-keys -t "$SESSION" Enter
```

`log` appends the numbered exchange to `interview.md`. Write the phase
headings (`## Specify interview`, `## Architecture interview`) and gate
outcomes into it by hand. Before preserving the run (§7), audit the whole log:

```bash
"${I[@]}" check
```

Any `ERROR` voids the run as operator answer drift. Each `WARN` names a
decision a human must be able to defend from the key. Record that defence in
`interview.md` or void the run.

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
"${T[@]}" kill-session -t "$SESSION" 2>/dev/null || true
git -C ~/dev/claude-plugins/loom worktree remove '<worktree>'
```

Restore Cortex only after the final repetition in the batch.
