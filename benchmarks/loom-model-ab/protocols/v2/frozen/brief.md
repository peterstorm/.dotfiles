# Benchmark brief v2 — given verbatim to `/loom` in every arm and repetition

Paste the block below as the argument to `/loom`. Do not reword it between
runs; a changed brief is a changed experiment.

---

Build the functional core of Loom's shipped parent-relayed Pi RPC UI transport.
Read these files first; together they are the requirements authority, in this
order:

1. `engine/src/core/ui-relay-wire-contract.md` — frozen raw JSONL wire schema;
2. `engine/src/core/ui-relay-types.ts` — frozen ADTs and function signatures;
3. `docs/pi-phase-agent-interviews.md` — architecture context only.

If current documentation is less precise than either frozen artifact, the
frozen artifact controls. Do not infer the raw wire from decoded domain tags:
Pi emits top-level `extension_ui_request` records and expects matching
`extension_ui_response` records.

Implement **only the pure core**:

- `engine/src/core/ui-relay.ts` — streaming byte decoder, hostile wire parser,
  and request/response correlation reducer;
- `engine/src/core/ui-relay.test.ts` — its tests.

The two frozen files already exist in the worktree. Do not edit them. Implement
every declaration in `ui-relay-types.ts` exactly as declared.

Out of scope: process spawning, stdio, timers, TUI rendering, Pi extension
registration, write grants, and child tool-allowlist configuration. The core is
pure: no `node:*` imports, clock, randomness, logging, or I/O. Recursive
delegation is enforced by the shell's child tool allowlist, not invented as a
wire method.

Treat child bytes as hostile. Enumerate framing, schema, correlation, terminal,
and immutability failure modes in the specification before designing. The
correctness bar is Loom's `engine/src/core` standard: immutable discriminated
unions, parse-don't-validate boundaries, typed errors rather than exceptions,
no `any`, and branch-complete tests without mocks. `bunx tsc --noEmit` and the
new tests must pass before implementation could be called done.

## Planning-only stop condition

For this run, complete Loom through brainstorm, specification, architecture,
plan alignment, and task decomposition. Produce an execution-ready task graph,
then stop immediately before Wave 1.

**Do not start implementation. Do not launch an implementer, test, reviewer,
ADR-writer, or wave-gate child. Do not edit production code, tests,
documentation, or either frozen file.** The expected terminal graph has entered
`execute` only because decomposition is complete: `current_wave` is `1`, every
task is still `pending`, `executing_tasks` is empty, and no wave gate has run.
