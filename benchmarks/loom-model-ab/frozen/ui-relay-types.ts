/**
 * FROZEN CONTRACT — do not edit.
 *
 * The wave-0 types artifact for the parent-relayed UI transport. Downstream
 * work compiles against this surface, so its names, arities, and shapes are
 * fixed. Implement against it as declared; changes belong in a separate
 * change to the contract, not in an implementation task.
 */

/** Result of a total function over caller-supplied values. Never throws. */
export type RelayResult<T> =
  | Readonly<{ ok: true; value: T }>
  | Readonly<{ ok: false; error: RelayError }>;

export type RelayErrorKind =
  | "malformed-frame"
  | "unknown-method"
  | "unknown-request"
  | "duplicate-request"
  | "recursive-delegation"
  | "response-mismatch";

export type RelayError = Readonly<{
  kind: RelayErrorKind;
  /** Human-readable diagnostic. Never used for control flow. */
  message: string;
}>;

/** Opaque correlation id. Constructed only by `parseRequestId`. */
export type RequestId = string & { readonly __brand: "RequestId" };

/**
 * A non-empty, non-whitespace string is a valid id. Everything else is a
 * typed failure — ids are parsed once at the boundary, never re-validated.
 */
export declare function parseRequestId(raw: unknown): RelayResult<RequestId>;

export type UiRequest = Readonly<
  | { method: "select"; id: RequestId; prompt: string; options: readonly string[] }
  | { method: "confirm"; id: RequestId; prompt: string }
  | { method: "input"; id: RequestId; prompt: string }
  | { method: "editor"; id: RequestId; prompt: string; initial: string }
>;

export type UiAnswer = Readonly<
  | { method: "select"; index: number }
  | { method: "confirm"; accepted: boolean }
  | { method: "input"; value: string }
  | { method: "editor"; value: string }
>;

export type CancelReason = "timeout" | "user-cancelled" | "child-exited" | "parent-shutdown";

export type UiOutcome =
  | Readonly<{ status: "answered"; answer: UiAnswer }>
  | Readonly<{ status: "cancelled"; reason: CancelReason }>;

export type ChildFrame =
  | Readonly<{ type: "ui-request"; request: UiRequest }>
  | Readonly<{ type: "progress"; text: string }>
  | Readonly<{ type: "done" }>;

// ---------------------------------------------------------------------------
// Streaming decode
// ---------------------------------------------------------------------------

/** Carry holds the trailing partial line between chunks. */
export type DecodeState = Readonly<{ carry: string }>;

export type DecodeOutput = Readonly<{
  state: DecodeState;
  frames: readonly ChildFrame[];
  errors: readonly RelayError[];
}>;

export declare const emptyDecodeState: DecodeState;

/**
 * Decode one stdout chunk of strict LF-delimited JSONL.
 *
 * A malformed line yields an error and does NOT abort decoding of the
 * remaining complete lines in the same chunk. Only `\n` terminates a line;
 * a trailing `\r` is part of the line and therefore malformed JSON.
 */
export declare function decodeChunk(state: DecodeState, chunk: string): DecodeOutput;

// ---------------------------------------------------------------------------
// Correlation machine
// ---------------------------------------------------------------------------

export type RelayState = Readonly<{
  /** Outstanding requests in arrival order. */
  pending: readonly UiRequest[];
  /** Terminal flag. Once true, the machine accepts no further work. */
  closed: boolean;
}>;

export declare const initialRelayState: RelayState;

export type RelayEvent =
  | Readonly<{ type: "frame"; frame: ChildFrame }>
  | Readonly<{ type: "answer"; id: RequestId; answer: UiAnswer }>
  | Readonly<{ type: "cancel"; id: RequestId; reason: CancelReason }>
  | Readonly<{ type: "child-exited" }>
  | Readonly<{ type: "parent-shutdown" }>;

export type RelayEffect =
  | Readonly<{ type: "prompt-user"; request: UiRequest }>
  | Readonly<{ type: "send-response"; id: RequestId; outcome: UiOutcome }>
  | Readonly<{ type: "show-progress"; text: string }>
  | Readonly<{ type: "close-child" }>;

export type RelayStep = Readonly<{
  state: RelayState;
  effects: readonly RelayEffect[];
  errors: readonly RelayError[];
}>;

/**
 * Pure reducer. Must not mutate `state`, must not perform I/O, and must be
 * deterministic: the same (state, event) always yields the same step.
 */
export declare function relayStep(state: RelayState, event: RelayEvent): RelayStep;
