# Frozen v2 Pi RPC wire contract

**Status:** model-visible benchmark input; do not edit.

This is the raw-wire authority for protocol v2. It is frozen from Loom baseline
`3815f65bfab4351f49f0e21e7b7415cdab1fda86`, whose
`pi/interactive-rpc.ts` SHA-256 is
`96db189bf2012378c1874b9168d328108a199df9b6d0633a23f18a9355bc21e0`.
The baseline source and current Loom source are byte-identical at that path.

The TypeScript ADTs and function signatures are frozen separately in
`ui-relay-types.ts`. This document specifies the hostile JSONL records those
ADTs parse. Do not substitute decoded domain tags for these wire records.

## Framing

- Input is UTF-8 bytes split into records by byte `0x0a` (LF).
- One `0x0d` immediately before LF is stripped, so both LF and CRLF records are
  accepted.
- U+2028 and U+2029 inside JSON strings are ordinary content, not delimiters.
- A record or unterminated carry may not exceed 4 MiB.
- End-of-stream with a non-empty carry is an error.
- Empty records, malformed JSON, non-object JSON, and objects without a
  non-empty string `type` are malformed.

## UI request envelope

Every UI request is a top-level object with:

```json
{"type":"extension_ui_request","id":"request-id","method":"..."}
```

`id` and `method` are non-empty strings. They are not trimmed. Unknown extra
fields are tolerated. The supported methods and method-specific fields are:

| Wire method | Required fields | Optional/defaulted fields | Parsed variant |
|---|---|---|---|
| `select` | non-empty `title`; non-empty `options` array of non-empty strings | positive-integer `timeout` | `select` |
| `confirm` | non-empty `title`; string `message` | positive-integer `timeout` | `confirm` |
| `input` | non-empty `title` | string `placeholder`; positive-integer `timeout` | `input` |
| `editor` | non-empty `title`; string `prefill` | none | `editor` |
| `notify` | non-empty `message` | `notifyType`: `info` by default, or `warning`/`error` | `notify` |
| `setStatus` | non-empty `statusKey` | string `statusText` | `set-status` |
| `setWidget` | non-empty `widgetKey` | `widgetLines`: array of non-empty strings, including an empty array; `widgetPlacement`: `aboveEditor` by default or `belowEditor` | `set-widget` |
| `setTitle` | non-empty `title` | none | `set-title` |
| `set_editor_text` | non-empty `text` | none | `set-editor-text` |

An unsupported `extension_ui_request.method` is an
`unsupported-ui-method` error. Missing or ill-typed fields are
`malformed-frame` errors.

The first four methods are answer-bearing dialogs. The other five are
fire-and-forget UI operations and must never create a pending response.

## Responses written to child stdin

Responses preserve the request id exactly:

```json
{"type":"extension_ui_response","id":"request-id","value":"selected or entered text"}
{"type":"extension_ui_response","id":"request-id","confirmed":true}
{"type":"extension_ui_response","id":"request-id","cancelled":true}
```

`select`, `input`, and `editor` produce `value`; `confirm` produces
`confirmed`; any dialog can produce `cancelled`. A selected value must be one
of that request's options. A response with the wrong shape or id is not sent.

## Non-UI Pi events and terminal behavior

A top-level object with any other non-empty string `type` is a generic Pi event,
not an unknown UI method. Its complete object payload is retained. In
particular, `agent_settled` is the successful terminal event. It settles the
relay and terminates the child; any pending dialog at that point is a
`protocol-state` error.

Child exit before `agent_settled` fails closed. Parent abort sends the Pi RPC
`abort` command and terminates the child. Once settled, later events are no-ops.

Recursive delegation is not a wire method. Loom prevents it through the RPC
child's tool allowlist: `subagent` and `loom_interactive_subagent` are absent.
The v1 `spawn`/`subagent`/`task` wire-method rule is retired and must not appear
in a v2 plan.
