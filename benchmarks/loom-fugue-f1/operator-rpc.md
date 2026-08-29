# Supervised RPC operator procedure

Use the command printed by `scripts/run-arm.sh`. Do not launch an interactive
Pi TUI or scrape tmux.

1. Keep `frozen/answer-key.md` open outside Pi.
2. For each RPC dialog, choose or enter only the scripted answer. The driver
   writes the exact request and response to `interview.md`.
3. Approve artifact gates without commentary. If an artifact is empty or cites
   a nonexistent file, cancel and preserve the run; do not repair it.
4. Never answer an implementation/review/test/wave-gate child.
5. The driver watches `.claude/state/active_task_graph.json` and sends `abort`
   as soon as it observes execute/wave 1 with all tasks pending. If a task
   begins anyway, preserve the run; mechanical grading marks it invalid.
6. Do not run Cortex or Obsidian until every matched arm is complete.

The driver stores:

- `rpc-events.jsonl`: exact Pi output frames;
- `rpc-commands.jsonl`: commands/responses sent by the driver;
- `interview.md`: UI questions and operator answers;
- `session.jsonl`: copied Pi session used for model/output attestation;
- `driver-receipt.json`: termination and boundary facts.

Transport errors, malformed frames, missing session files, or failure to reach
the boundary are evidence. Do not switch to manual keystrokes mid-run.
