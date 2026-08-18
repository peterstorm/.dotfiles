# Hidden reference spec — Parent-relayed UI request codec and correlation core

**Status:** HIDDEN. Never enters a benchmark worktree and is never shown to a
model or to a live run.

This is not the input the arms receive — they receive `frozen/brief.md` and must
write their own spec. This document is the grader's answer key. It serves two
purposes:

1. it is the requirement set the hidden acceptance suite enforces; and
2. it is the **discovery checklist** — for each FR below, record whether the
   arm's own `spec.md` identified the requirement, whether its `plan.md`
   accounted for it, and whether its implementation satisfies it.

Discovery and satisfaction are scored as orthogonal facts. An arm that never
wrote down the CRLF rule but happens to pass FR-013 got there by luck, and an
arm that specified it precisely and then failed the test has a different defect.
Do not collapse the two columns.

## Context

Loom phase Agents on Pi run as headless child processes. A child that needs to
question the user and the TUI that contains the user are different processes.
`docs/pi-phase-agent-interviews.md` recommends a parent-relayed RPC child: the
parent spawns `pi --mode rpc`, reads the child's strict LF-delimited JSONL
stdout, renders `extension_ui_request` dialogs in its own TUI, and writes the
matching `extension_ui_response` to child stdin.

This task builds **only the functional core** of that relay: frame decoding and
request/response correlation. Process spawning, stdio wiring, and TUI rendering
are the imperative shell and are explicitly out of scope.

## Scope

**In scope**

- `engine/src/core/ui-relay-types.ts` — frozen, provided, must not be edited.
- `engine/src/core/ui-relay.ts` — implement `parseRequestId`, `emptyDecodeState`,
  `decodeChunk`, `initialRelayState`, `relayStep`.
- Tests for the above.

**Out of scope**

- Spawning a child process, stdio plumbing, timers, TUI rendering.
- Any Pi extension registration or write-grant work.
- Any change to files other than `ui-relay.ts` and its own test file.

## Functional requirements

### Ids

- **FR-001** `parseRequestId` accepts a string containing at least one
  non-whitespace character and returns it branded as `RequestId`.
- **FR-002** `parseRequestId` returns a `malformed-frame` failure for any
  non-string, the empty string, or a whitespace-only string.

### Decoding (`decodeChunk`)

- **FR-010** Only `\n` terminates a line. The decoder returns one frame per
  complete line, in order.
- **FR-011** A chunk not ending in `\n` leaves its trailing partial line in
  `state.carry` and emits no frame for it. The next chunk continues that line,
  across arbitrarily many chunks.
- **FR-012** A line that is not valid JSON yields a `malformed-frame` error.
  Decoding continues with the remaining complete lines in the same chunk — one
  bad line never discards a good one.
- **FR-013** A trailing `\r` before the `\n` is part of the line. Because that
  makes the line invalid JSON, CRLF input yields `malformed-frame`. The decoder
  must not strip `\r`.
- **FR-014** An empty line is a protocol error, not a silent skip: it yields
  `malformed-frame`.
- **FR-015** Recognised wire methods are exactly `select`, `confirm`, `input`,
  `editor`, `progress`, and `done`. Any other `method` yields `unknown-method`.
- **FR-016** A wire method of `spawn`, `subagent`, or `task` yields
  `recursive-delegation` — the RPC child may never delegate further. This takes
  precedence over FR-015.
- **FR-017** A frame missing a required field for its method, or holding one of
  the wrong type, yields `malformed-frame`. Required fields: `select` needs
  `id`, `prompt`, `options`; `confirm` and `input` need `id` and `prompt`;
  `editor` needs `id`, `prompt`, `initial`; `progress` needs `text`; `done`
  needs nothing.
- **FR-018** A `select` with an empty `options` array yields `malformed-frame` —
  an unanswerable dialog is a protocol error, not an empty menu.
- **FR-019** `decodeChunk` never throws and never returns a frame alongside an
  error for the same line.

### Correlation (`relayStep`)

- **FR-030** A `ui-request` frame appends the request to `pending` (arrival
  order preserved) and emits exactly one `prompt-user` effect.
- **FR-031** A `ui-request` whose id is already pending yields
  `duplicate-request`, leaves `pending` unchanged, and emits no effect.
- **FR-032** An `answer` for a pending id emits one `send-response` with
  `{ status: "answered" }` and removes that request from `pending`.
- **FR-033** An `answer` whose `method` differs from the pending request's
  method yields `response-mismatch`. The request stays pending and no response
  is sent.
- **FR-034** A `select` answer whose `index` is negative or `>= options.length`
  yields `response-mismatch`. The request stays pending.
- **FR-035** An `answer` or `cancel` for an id that is not pending — never seen,
  or already resolved — yields `unknown-request` and emits no effect. Exactly
  one response is sent per request, ever.
- **FR-036** A `cancel` for a pending id emits one `send-response` with
  `{ status: "cancelled", reason }` carrying the event's reason, and removes the
  request from `pending`.
- **FR-037** `child-exited` emits one cancelled `send-response` with reason
  `child-exited` for every pending request, in arrival order, then sets
  `closed: true` and `pending: []`.
- **FR-038** `parent-shutdown` behaves as FR-037 with reason `parent-shutdown`,
  and additionally emits a trailing `close-child` effect.
- **FR-039** A `done` frame sets `closed: true` and emits `close-child`. Any
  requests still pending are cancelled first with reason `child-exited`.
- **FR-040** A `progress` frame emits one `show-progress` effect and leaves
  `pending` unchanged.
- **FR-041** Once `closed` is true, every event is a no-op: state is returned
  unchanged with no effects and no errors.
- **FR-042** `relayStep` is pure — it never mutates the state it is given, never
  performs I/O, and is deterministic in `(state, event)`.

## Non-functional requirements

- **NFR-001** Functional core only. No imports from `node:*`, no clock, no
  randomness, no logging.
- **NFR-002** Errors are returned as values. No exceptions for expected
  failures, and no `any`.
- **NFR-003** Illegal states unrepresentable where the type system allows it:
  discriminated unions over the wire methods, branded ids, `readonly`
  throughout.
- **NFR-004** Every branch above is covered by a test the implementer writes.

## Success criteria

- **SC-001** `bunx tsc --noEmit` is clean.
- **SC-002** The implementer's own test suite passes.
- **SC-003** `ui-relay-types.ts` is byte-identical to the frozen copy.
- **SC-004** No file outside `engine/src/core/ui-relay.ts` and its test file is
  modified.
