# Hidden v2 reference — current Pi RPC UI relay core

**Status:** HIDDEN. Never copied into a benchmark worktree or shown to a live
run. Grade only v2 runs against this file.

The model-visible authority is `protocols/v2/frozen/wire-contract.md` plus
`ui-relay-types.ts`. This checklist encodes that same contract's observable
edge cases. It must never contradict the visible authority.

## Functional requirements

### Request ids

- **FR-001** `parseRequestId` accepts every non-empty string verbatim, including
  whitespace, and returns a branded `RequestId`; it never trims or normalizes.
- **FR-002** `parseRequestId` returns `malformed-frame` for the empty string and
  every non-string value.

### Streaming decode and hostile wire parsing

- **FR-010** Only LF byte `0x0a` terminates a record. One CR byte immediately
  before LF is stripped, so LF and CRLF records decode identically. U+2028 and
  U+2029 inside JSON strings never split records.
- **FR-011** Bytes after the final LF remain in immutable `state.carry` across
  arbitrarily many chunks. UTF-8 code points split across chunks are preserved.
- **FR-012** Each complete record and the unterminated carry are capped at
  `MAX_RPC_FRAME_BYTES` measured in bytes, not JavaScript characters. An
  oversized record yields `malformed-frame` and no frame for that record.
- **FR-013** `finishDecode` succeeds only for an empty carry. End-of-stream with
  any unterminated bytes yields `malformed-frame`.
- **FR-014** Empty records, malformed JSON, non-object JSON, and objects without
  a non-empty string `type` yield `malformed-frame`. One bad complete record
  does not discard later complete records from the same chunk, and one record
  never produces both a frame and an error.
- **FR-015** A top-level `type: "extension_ui_request"` record is parsed as the
  UI envelope. Every other non-empty string `type`, including `message_end`,
  `extension_error`, `response`, and `agent_settled`, becomes a generic event
  retaining its complete object payload.
- **FR-016** Dialog methods map exactly: `select` requires non-empty `title` and
  a non-empty array of non-empty string `options`; `confirm` requires non-empty
  `title` and string `message`; `input` requires non-empty `title` and permits
  optional string `placeholder`; `editor` requires non-empty `title` and string
  `prefill`. Select/confirm/input permit optional positive-integer `timeout`;
  editor does not add one to the parsed variant.
- **FR-017** Fire-and-forget methods map exactly: `notify` requires non-empty
  `message` and defaults `notifyType` to `info`; `setStatus` maps non-empty
  `statusKey` plus optional string `statusText`; `setWidget` maps non-empty
  `widgetKey`, optional arrays of non-empty strings (empty array allowed), and
  defaults placement to `aboveEditor`; `setTitle` requires non-empty `title`;
  `set_editor_text` requires non-empty `text`.
- **FR-018** Every UI request requires a non-empty string id. Unsupported
  `extension_ui_request.method` yields `unsupported-ui-method`; missing or
  ill-typed fields, invalid timeout, notify type, widget placement, or array
  entries yield `malformed-frame`. Unknown extra fields are tolerated.
- **FR-019** `decodeChunk`, `finishDecode`, and `parseRequestId` are total for
  caller-supplied values: expected failures are returned, never thrown, and all
  returned arrays/records are fresh immutable values.

### Correlation reducer

- **FR-030** The first answer-bearing dialog id is added to both
  `seenRequestIds` and `pending` in arrival order and emits exactly one
  `prompt-user` effect.
- **FR-031** The first fire-and-forget request id is added only to
  `seenRequestIds`, emits exactly one `render-ui`, and never enters `pending` or
  produces `send-response`.
- **FR-032** Reusing any seen id—pending, resolved, cancelled, or
  fire-and-forget—yields `duplicate-request`, leaves state unchanged, and emits
  no effect.
- **FR-033** A matching select/input/editor answer emits one
  `extension_ui_response` with the exact id and `value`; a matching confirm
  emits the exact id and `confirmed`. The request is removed from `pending` but
  remains in `seenRequestIds`.
- **FR-034** An answer whose method differs from the pending dialog yields
  `response-mismatch`, sends nothing, and leaves the request pending. A select
  value not present in that request's options has the same result.
- **FR-035** An answer for an id not currently pending—including never seen,
  fire-and-forget, or already resolved—yields `unknown-request` and sends
  nothing. At most one response is ever sent for one request id.
- **FR-036** A `cancelled` answer for any pending dialog emits exactly
  `{type:"extension_ui_response", id, cancelled:true}` and removes it from
  `pending`.
- **FR-037** A generic nonterminal event emits one `observe-event` preserving
  `eventType` and payload and leaves correlation state unchanged.
- **FR-038** An `agent_settled` event with no pending dialog sets
  `settled:true`, emits exactly one `terminate-child`, and does not emit
  `observe-event`.
- **FR-039** `agent_settled` with pending dialogs still settles, clears pending,
  and terminates, but also yields `protocol-state`; it never fabricates UI
  responses for requests the user did not answer.
- **FR-040** `child-exited` before settlement clears pending, sets settled,
  emits `terminate-child`, and yields `protocol-state`. Child exit after
  settlement is covered by the universal settled-state no-op.
- **FR-041** `parent-abort` clears pending, sets settled, and emits `send-abort`
  followed by `terminate-child`; it sends no `extension_ui_response`.
- **FR-042** Once `settled` is true, every event is a no-op returning equivalent
  state with no effects or errors.
- **FR-043** `relayStep` is pure, immutable, deterministic, performs no I/O, and
  never throws for a value admitted by `RelayEvent`.

## Non-functional requirements

- **NFR-001** Functional core only: no `node:*`, process, stdio, clock,
  randomness, logging, TUI, extension registration, or child tool configuration.
- **NFR-002** No `any`; use discriminated unions, readonly data, exhaustive
  branches, and typed failures.
- **NFR-003** Tests cover every FR without mocks. Include byte-chunk framing,
  method-table examples, reducer transitions, immutability, and determinism.
- **NFR-004** Recursive delegation is explicitly out of scope and must not be
  modeled as a Pi RPC wire method.

## Success criteria

- **SC-001** `bunx tsc --noEmit` is clean.
- **SC-002** `engine/src/core/ui-relay.test.ts` passes.
- **SC-003** Both frozen files are byte-identical to protocol v2.
- **SC-004** No file outside `engine/src/core/ui-relay.ts` and
  `engine/src/core/ui-relay.test.ts` is modified by implementation.
