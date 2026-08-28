# Benchmark brief — given verbatim to `/loom` in every arm and repetition

Paste the block below as the argument to `/loom`. Do not reword it between
runs; a changed brief is a changed experiment.

---

Build the functional core of the parent-relayed UI request transport described
in `docs/pi-phase-agent-interviews.md` (read it first — the "Parent-relayed RPC
child" section and the "Recommended implementation boundary" list are the
requirements source).

Loom phase Agents on Pi run as headless child processes. A child that needs to
question the user and the TUI that contains the user are different processes.
The recommended design has the parent spawn `pi --mode rpc`, read the child's
strict LF-delimited JSONL stdout, render each `extension_ui_request` as a
dialog in the parent TUI, and write the exactly-matching
`extension_ui_response` back to the child's stdin.

Implement **only the pure core** of that transport:

- `engine/src/core/ui-relay.ts` — a streaming JSONL frame decoder and a
  request/response correlation reducer.
- Tests for it.

`engine/src/core/ui-relay-types.ts` already exists in the repository. It is a
frozen wave-0 types artifact: it declares every type and every function
signature you must implement. **Do not edit it.** Implement `ui-relay.ts`
against it exactly as declared — the names, arities, and shapes are fixed
because other work depends on them.

Out of scope, and you must not write any of it: process spawning, stdio
plumbing, timers, TUI rendering, Pi extension registration, write grants. The
core is pure — no `node:*` imports, no clock, no randomness, no I/O.

The correctness bar is the one Loom applies to its own `engine/src/core`:
functional core with an imperative shell elsewhere, errors returned as typed
values rather than thrown, illegal states made unrepresentable, immutability
throughout, and no `any`. `bunx tsc --noEmit` must be clean and your tests must
pass before you call the work done.

Think hard about the failure modes a real duplex transport hits — the ones a
naive implementation gets wrong are exactly what this core exists to prevent.
Enumerate them in the spec before you design.

## Planning-only stop condition

For this run, complete Loom through brainstorm, specification, architecture,
plan alignment, and task decomposition. Produce an execution-ready task graph,
then stop at the boundary immediately before Wave 1 would begin.

**Do not start implementation. Do not launch an implementer, test, reviewer, or
wave-gate child. Do not edit production code, tests, documentation, or the
frozen types file.** The expected terminal graph has entered the `execute`
phase only in the sense that decomposition is complete: `current_wave` is `1`,
every task is still `pending`, `executing_tasks` is empty, and no wave gate has
run.
