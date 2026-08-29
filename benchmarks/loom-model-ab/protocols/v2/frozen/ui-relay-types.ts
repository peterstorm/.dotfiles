/**
 * FROZEN V2 CONTRACT — do not edit.
 *
 * This contract models the Pi 0.83.0 RPC wire used by Loom's shipped
 * `loom_interactive_subagent` transport. Raw child records use Pi's
 * `extension_ui_request` envelope. They are not decoded `ChildFrame` values.
 */

export const MAX_RPC_FRAME_BYTES = 4 * 1024 * 1024;

export type RelayResult<T> =
  | Readonly<{ ok: true; value: T }>
  | Readonly<{ ok: false; error: RelayError }>;

export type RelayErrorKind =
  | "malformed-frame"
  | "unsupported-ui-method"
  | "duplicate-request"
  | "unknown-request"
  | "response-mismatch"
  | "protocol-state";

export type RelayError = Readonly<{
  kind: RelayErrorKind;
  message: string;
}>;

/** Opaque, non-empty Pi correlation id. Whitespace is data and is not trimmed. */
export type RequestId = string & { readonly __brand: "RequestId" };
export declare function parseRequestId(raw: unknown): RelayResult<RequestId>;

export type DialogUiRequest =
  | Readonly<{
      kind: "select";
      id: RequestId;
      title: string;
      options: readonly string[];
      timeout?: number;
    }>
  | Readonly<{
      kind: "confirm";
      id: RequestId;
      title: string;
      message: string;
      timeout?: number;
    }>
  | Readonly<{
      kind: "input";
      id: RequestId;
      title: string;
      placeholder?: string;
      timeout?: number;
    }>
  | Readonly<{
      kind: "editor";
      id: RequestId;
      title: string;
      prefill: string;
    }>;

export type FireAndForgetUiRequest =
  | Readonly<{
      kind: "notify";
      id: RequestId;
      message: string;
      notifyType: "info" | "warning" | "error";
    }>
  | Readonly<{
      kind: "set-status";
      id: RequestId;
      key: string;
      text?: string;
    }>
  | Readonly<{
      kind: "set-widget";
      id: RequestId;
      key: string;
      lines?: readonly string[];
      placement: "aboveEditor" | "belowEditor";
    }>
  | Readonly<{ kind: "set-title"; id: RequestId; title: string }>
  | Readonly<{ kind: "set-editor-text"; id: RequestId; text: string }>;

export type ExtensionUiRequest = DialogUiRequest | FireAndForgetUiRequest;

/**
 * Exact response records written to Pi RPC stdin. Select/input/editor use
 * `value`; confirm uses `confirmed`; cancellation uses `cancelled`.
 */
export type ExtensionUiResponse =
  | Readonly<{ type: "extension_ui_response"; id: RequestId; value: string }>
  | Readonly<{ type: "extension_ui_response"; id: RequestId; confirmed: boolean }>
  | Readonly<{ type: "extension_ui_response"; id: RequestId; cancelled: true }>;

export type PiRpcFrame =
  | Readonly<{ kind: "extension-ui"; request: ExtensionUiRequest }>
  | Readonly<{
      kind: "event";
      eventType: string;
      payload: Readonly<Record<string, unknown>>;
    }>;

// ---------------------------------------------------------------------------
// Streaming byte decode
// ---------------------------------------------------------------------------

/** Bytes after the final complete LF-delimited record. */
export type DecodeState = Readonly<{ carry: readonly number[] }>;

export type DecodeOutput = Readonly<{
  state: DecodeState;
  frames: readonly PiRpcFrame[];
  errors: readonly RelayError[];
}>;

export declare const emptyDecodeState: DecodeState;

/**
 * Decode complete LF-delimited UTF-8 JSON records from one byte chunk.
 * CRLF is accepted by stripping one CR immediately before LF. U+2028 and
 * U+2029 are ordinary JSON string content. A bad complete line yields one
 * error and does not discard later complete lines from the same chunk.
 */
export declare function decodeChunk(state: DecodeState, chunk: Uint8Array): DecodeOutput;

/** An empty carry succeeds; any unterminated bytes fail closed. */
export declare function finishDecode(state: DecodeState): RelayResult<readonly []>;

// ---------------------------------------------------------------------------
// Correlation reducer
// ---------------------------------------------------------------------------

export type RelayState = Readonly<{
  /** Every request id observed in this child session, including resolved ids. */
  seenRequestIds: readonly RequestId[];
  /** Outstanding answer-bearing requests in arrival order. */
  pending: readonly DialogUiRequest[];
  /** True after agent_settled, child exit, or parent abort. */
  settled: boolean;
}>;

export declare const initialRelayState: RelayState;

export type UiAnswer =
  | Readonly<{ method: "select"; value: string }>
  | Readonly<{ method: "confirm"; confirmed: boolean }>
  | Readonly<{ method: "input"; value: string }>
  | Readonly<{ method: "editor"; value: string }>
  | Readonly<{ method: "cancelled" }>;

export type RelayEvent =
  | Readonly<{ type: "frame"; frame: PiRpcFrame }>
  | Readonly<{ type: "answer"; id: RequestId; answer: UiAnswer }>
  | Readonly<{ type: "child-exited" }>
  | Readonly<{ type: "parent-abort" }>;

export type RelayEffect =
  | Readonly<{ type: "prompt-user"; request: DialogUiRequest }>
  | Readonly<{ type: "render-ui"; request: FireAndForgetUiRequest }>
  | Readonly<{ type: "send-response"; response: ExtensionUiResponse }>
  | Readonly<{
      type: "observe-event";
      eventType: string;
      payload: Readonly<Record<string, unknown>>;
    }>
  | Readonly<{ type: "send-abort" }>
  | Readonly<{ type: "terminate-child" }>;

export type RelayStep = Readonly<{
  state: RelayState;
  effects: readonly RelayEffect[];
  errors: readonly RelayError[];
}>;

/** Pure, immutable and deterministic in `(state, event)`. */
export declare function relayStep(state: RelayState, event: RelayEvent): RelayStep;
