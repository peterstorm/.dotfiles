/** HIDDEN V2 ACCEPTANCE SUITE — never place inside an arm worktree. */
import { describe, expect, it } from "vitest";
import fc from "fast-check";
import {
  decodeChunk,
  emptyDecodeState,
  finishDecode,
  initialRelayState,
  parseRequestId,
  relayStep,
} from "../../src/core/ui-relay";
import { MAX_RPC_FRAME_BYTES } from "../../src/core/ui-relay-types";
import type {
  DialogUiRequest,
  PiRpcFrame,
  RelayEffect,
  RelayEvent,
  RelayState,
  RequestId,
} from "../../src/core/ui-relay-types";

const utf8 = (value: string): Uint8Array => new TextEncoder().encode(value);
const line = (value: unknown, ending = "\n"): Uint8Array => utf8(`${JSON.stringify(value)}${ending}`);
const ui = (method: string, fields: Readonly<Record<string, unknown>>): Uint8Array =>
  line({ type: "extension_ui_request", id: "r1", method, ...fields });
const kinds = (value: { errors: readonly { kind: string }[] }): readonly string[] =>
  value.errors.map((error) => error.kind);

const id = (raw: string): RequestId => {
  const parsed = parseRequestId(raw);
  if (!parsed.ok) throw new Error("invalid fixture id");
  return parsed.value;
};

const dialog = (rawId: string, kind: DialogUiRequest["kind"] = "input"): DialogUiRequest => {
  if (kind === "select") return { kind, id: id(rawId), title: "Pick", options: ["A", "B"] };
  if (kind === "confirm") return { kind, id: id(rawId), title: "Continue", message: "Proceed?" };
  if (kind === "editor") return { kind, id: id(rawId), title: "Edit", prefill: "" };
  return { kind, id: id(rawId), title: "Input" };
};

const requestFrame = (request: DialogUiRequest): PiRpcFrame => ({ kind: "extension-ui", request });

const run = (events: readonly RelayEvent[]): Readonly<{ state: RelayState; effects: readonly RelayEffect[]; errors: readonly string[] }> => {
  let state = initialRelayState;
  const effects: RelayEffect[] = [];
  const errors: string[] = [];
  for (const event of events) {
    const step = relayStep(state, event);
    state = step.state;
    effects.push(...step.effects);
    errors.push(...step.errors.map((error) => error.kind));
  }
  return { state, effects, errors };
};

describe("v2 request ids", () => {
  it("preserves every non-empty string verbatim [FR-001]", () => {
    for (const raw of ["r1", " ", "\t"]) {
      const parsed = parseRequestId(raw);
      expect(parsed).toEqual({ ok: true, value: raw });
    }
  });

  it("rejects empty and non-string ids [FR-002]", () => {
    for (const raw of ["", null, 1, {}, []]) {
      const parsed = parseRequestId(raw);
      expect(parsed.ok).toBe(false);
      if (!parsed.ok) expect(parsed.error.kind).toBe("malformed-frame");
    }
  });
});

describe("v2 byte framing", () => {
  it("accepts LF and CRLF and ignores Unicode separators [FR-010]", () => {
    const record = { type: "message_end", text: `a\u2028b\u2029c` };
    for (const ending of ["\n", "\r\n"]) {
      const output = decodeChunk(emptyDecodeState, line(record, ending));
      expect(output.errors).toEqual([]);
      expect(output.frames).toEqual([{ kind: "event", eventType: "message_end", payload: record }]);
    }
  });

  it("reassembles arbitrary chunks including a split UTF-8 code point [FR-011]", () => {
    const bytes = line({ type: "message_end", text: "before 😀 after" });
    let state = emptyDecodeState;
    const frames: PiRpcFrame[] = [];
    for (const byte of bytes) {
      const output = decodeChunk(state, Uint8Array.of(byte));
      state = output.state;
      frames.push(...output.frames);
      expect(output.errors).toEqual([]);
    }
    expect(frames).toHaveLength(1);
    expect(state.carry).toEqual([]);
  });

  it("is invariant under arbitrary positive byte chunking [FR-011]", () => {
    fc.assert(fc.property(
      fc.array(fc.string(), { minLength: 1, maxLength: 12 }),
      fc.array(fc.integer({ min: 1, max: 31 }), { minLength: 1, maxLength: 20 }),
      (values, chunkSizes) => {
        const bytes = utf8(`${values.map((value, index) => JSON.stringify({
          type: "message_end", index, value,
        })).join("\n")}\n`);
        let state = emptyDecodeState;
        const frames: PiRpcFrame[] = [];
        let offset = 0;
        let chunkIndex = 0;
        while (offset < bytes.length) {
          const size = chunkSizes[chunkIndex % chunkSizes.length]!;
          const output = decodeChunk(state, bytes.subarray(offset, offset + size));
          expect(output.errors).toEqual([]);
          state = output.state;
          frames.push(...output.frames);
          offset += size;
          chunkIndex += 1;
        }
        expect(finishDecode(state)).toEqual({ ok: true, value: [] });
        expect(frames.map((frame) => frame.kind === "event" ? frame.payload.value : null)).toEqual(values);
      },
    ));
  });

  it("enforces the byte cap for records and carry [FR-012]", () => {
    const oversized = new Uint8Array(MAX_RPC_FRAME_BYTES + 2).fill(0x78);
    oversized[oversized.length - 1] = 0x0a;
    expect(kinds(decodeChunk(emptyDecodeState, oversized))).toEqual(["malformed-frame"]);
    const carry = decodeChunk(emptyDecodeState, new Uint8Array(MAX_RPC_FRAME_BYTES + 1).fill(0x78));
    expect(kinds(carry)).toEqual(["malformed-frame"]);
  });

  it("fails closed on an unterminated final record [FR-013]", () => {
    expect(finishDecode(emptyDecodeState)).toEqual({ ok: true, value: [] });
    const partial = decodeChunk(emptyDecodeState, utf8('{"type":"agent_settled"}'));
    const finished = finishDecode(partial.state);
    expect(finished.ok).toBe(false);
    if (!finished.ok) expect(finished.error.kind).toBe("malformed-frame");
  });

  it("isolates malformed complete records and continues [FR-014]", () => {
    const chunk = utf8('\nnull\n{bad\n{"type":"message_end","n":1}\n');
    const output = decodeChunk(emptyDecodeState, chunk);
    expect(kinds(output)).toEqual(["malformed-frame", "malformed-frame", "malformed-frame"]);
    expect(output.frames).toEqual([{
      kind: "event", eventType: "message_end", payload: { type: "message_end", n: 1 },
    }]);
  });
});

describe("v2 Pi RPC wire parser", () => {
  it("separates the UI envelope from generic Pi events [FR-015]", () => {
    const output = decodeChunk(emptyDecodeState, utf8(
      `${JSON.stringify({ type: "extension_ui_request", id: "r1", method: "input", title: "Name" })}\n` +
      `${JSON.stringify({ type: "agent_settled", extra: 1 })}\n`,
    ));
    expect(output.frames[0]).toMatchObject({ kind: "extension-ui", request: { kind: "input", id: "r1" } });
    expect(output.frames[1]).toEqual({
      kind: "event", eventType: "agent_settled", payload: { type: "agent_settled", extra: 1 },
    });
  });

  it("maps all dialog fields and defaults exactly [FR-016]", () => {
    const records = [
      ui("select", { title: "Pick", options: ["A"], timeout: 5 }),
      ui("confirm", { title: "Sure", message: "", timeout: 6 }),
      ui("input", { title: "Name", placeholder: "", timeout: 7 }),
      ui("editor", { title: "Edit", prefill: "" }),
    ];
    const output = decodeChunk(emptyDecodeState, Uint8Array.from(records.flatMap((record) => [...record])));
    expect(output.errors).toEqual([]);
    expect(output.frames.map((frame) => frame.kind === "extension-ui" ? frame.request.kind : null))
      .toEqual(["select", "confirm", "input", "editor"]);
  });

  it("maps fire-and-forget methods and defaults exactly [FR-017]", () => {
    const records = [
      ui("notify", { message: "hello" }),
      ui("setStatus", { statusKey: "phase", statusText: "planning" }),
      ui("setWidget", { widgetKey: "w", widgetLines: [], widgetPlacement: "belowEditor" }),
      ui("setTitle", { title: "Loom" }),
      ui("set_editor_text", { text: "draft" }),
    ];
    const output = decodeChunk(emptyDecodeState, Uint8Array.from(records.flatMap((record) => [...record])));
    expect(output.errors).toEqual([]);
    expect(output.frames.map((frame) => frame.kind === "extension-ui" ? frame.request : null)).toEqual([
      { kind: "notify", id: "r1", message: "hello", notifyType: "info" },
      { kind: "set-status", id: "r1", key: "phase", text: "planning" },
      { kind: "set-widget", id: "r1", key: "w", lines: [], placement: "belowEditor" },
      { kind: "set-title", id: "r1", title: "Loom" },
      { kind: "set-editor-text", id: "r1", text: "draft" },
    ]);
  });

  it("distinguishes unsupported methods from malformed fields [FR-018]", () => {
    expect(kinds(decodeChunk(emptyDecodeState, ui("custom", { title: "No" }))))
      .toEqual(["unsupported-ui-method"]);
    for (const wire of [
      { type: "extension_ui_request", id: "", method: "input", title: "Name" },
      { type: "extension_ui_request", id: "r", method: "select", title: "Pick", options: [] },
      { type: "extension_ui_request", id: "r", method: "select", title: "Pick", options: [""] },
      { type: "extension_ui_request", id: "r", method: "confirm", title: "Sure" },
      { type: "extension_ui_request", id: "r", method: "input", title: "Name", timeout: 0 },
      { type: "extension_ui_request", id: "r", method: "notify", message: "x", notifyType: "debug" },
      { type: "extension_ui_request", id: "r", method: "setWidget", widgetKey: "w", widgetPlacement: "side" },
    ]) expect(kinds(decodeChunk(emptyDecodeState, line(wire)))).toEqual(["malformed-frame"]);
    expect(decodeChunk(emptyDecodeState, line({
      type: "extension_ui_request", id: "r", method: "input", title: "Name", future: true,
    })).errors).toEqual([]);
  });

  it("is total and does not reuse mutable caller values [FR-019]", () => {
    const state = Object.freeze({ carry: Object.freeze([]) });
    expect(() => decodeChunk(state, line({ type: "message_end" }))).not.toThrow();
    expect(() => finishDecode(state)).not.toThrow();
    expect(() => parseRequestId({})).not.toThrow();
  });
});

describe("v2 correlation reducer", () => {
  it("registers and prompts for a dialog [FR-030]", () => {
    const request = dialog("r1");
    const step = relayStep(initialRelayState, { type: "frame", frame: requestFrame(request) });
    expect(step.state.seenRequestIds).toEqual(["r1"]);
    expect(step.state.pending).toEqual([request]);
    expect(step.effects).toEqual([{ type: "prompt-user", request }]);
  });

  it("renders fire-and-forget UI without pending or response [FR-031]", () => {
    const request = { kind: "notify", id: id("n1"), message: "Hi", notifyType: "info" } as const;
    const step = relayStep(initialRelayState, {
      type: "frame", frame: { kind: "extension-ui", request },
    });
    expect(step.state).toMatchObject({ seenRequestIds: ["n1"], pending: [] });
    expect(step.effects).toEqual([{ type: "render-ui", request }]);
  });

  it("rejects reuse of pending, resolved, and fire-and-forget ids [FR-032]", () => {
    const first = relayStep(initialRelayState, { type: "frame", frame: requestFrame(dialog("r1")) });
    const duplicate = relayStep(first.state, { type: "frame", frame: requestFrame(dialog("r1")) });
    expect(kinds(duplicate)).toEqual(["duplicate-request"]);
    expect(duplicate.effects).toEqual([]);
    expect(duplicate.state).toEqual(first.state);
  });

  it("emits exact method-correct responses and retains seen ids [FR-033]", () => {
    const select = dialog("s", "select");
    const confirm = dialog("c", "confirm");
    const result = run([
      { type: "frame", frame: requestFrame(select) },
      { type: "frame", frame: requestFrame(confirm) },
      { type: "answer", id: id("s"), answer: { method: "select", value: "A" } },
      { type: "answer", id: id("c"), answer: { method: "confirm", confirmed: false } },
    ]);
    expect(result.state).toMatchObject({ seenRequestIds: ["s", "c"], pending: [] });
    expect(result.effects).toContainEqual({
      type: "send-response", response: { type: "extension_ui_response", id: "s", value: "A" },
    });
    expect(result.effects).toContainEqual({
      type: "send-response", response: { type: "extension_ui_response", id: "c", confirmed: false },
    });
  });

  it("retains pending on method or select-value mismatch [FR-034]", () => {
    const first = relayStep(initialRelayState, { type: "frame", frame: requestFrame(dialog("s", "select")) });
    for (const answer of [
      { method: "confirm", confirmed: true } as const,
      { method: "select", value: "not-an-option" } as const,
    ]) {
      const step = relayStep(first.state, { type: "answer", id: id("s"), answer });
      expect(kinds(step)).toEqual(["response-mismatch"]);
      expect(step.state.pending).toHaveLength(1);
      expect(step.effects).toEqual([]);
    }
  });

  it("rejects unknown, nonpending, and already resolved ids [FR-035]", () => {
    const unknown = relayStep(initialRelayState, {
      type: "answer", id: id("ghost"), answer: { method: "input", value: "x" },
    });
    expect(kinds(unknown)).toEqual(["unknown-request"]);
    const result = run([
      { type: "frame", frame: requestFrame(dialog("r")) },
      { type: "answer", id: id("r"), answer: { method: "input", value: "first" } },
      { type: "answer", id: id("r"), answer: { method: "input", value: "second" } },
    ]);
    expect(result.effects.filter((effect) => effect.type === "send-response")).toHaveLength(1);
  });

  it("emits exact cancellation responses [FR-036]", () => {
    const result = run([
      { type: "frame", frame: requestFrame(dialog("r")) },
      { type: "answer", id: id("r"), answer: { method: "cancelled" } },
    ]);
    expect(result.effects).toContainEqual({
      type: "send-response", response: { type: "extension_ui_response", id: "r", cancelled: true },
    });
    expect(result.state.pending).toEqual([]);
  });

  it("forwards generic nonterminal events without changing state [FR-037]", () => {
    const payload = { type: "message_end", message: { role: "assistant" } };
    const step = relayStep(initialRelayState, {
      type: "frame", frame: { kind: "event", eventType: "message_end", payload },
    });
    expect(step.state).toEqual(initialRelayState);
    expect(step.effects).toEqual([{ type: "observe-event", eventType: "message_end", payload }]);
  });

  it("settles and terminates on agent_settled [FR-038]", () => {
    const step = relayStep(initialRelayState, {
      type: "frame", frame: { kind: "event", eventType: "agent_settled", payload: { type: "agent_settled" } },
    });
    expect(step.state).toEqual({ seenRequestIds: [], pending: [], settled: true });
    expect(step.effects).toEqual([{ type: "terminate-child" }]);
    expect(step.errors).toEqual([]);
  });

  it("fails closed when agent_settled arrives with pending dialogs [FR-039]", () => {
    const result = run([
      { type: "frame", frame: requestFrame(dialog("r")) },
      { type: "frame", frame: { kind: "event", eventType: "agent_settled", payload: { type: "agent_settled" } } },
    ]);
    expect(result.state).toMatchObject({ pending: [], settled: true });
    expect(result.effects.at(-1)).toEqual({ type: "terminate-child" });
    expect(result.errors).toContain("protocol-state");
  });

  it("fails closed on child exit before settlement [FR-040]", () => {
    const result = run([
      { type: "frame", frame: requestFrame(dialog("r")) },
      { type: "child-exited" },
    ]);
    expect(result.state).toMatchObject({ pending: [], settled: true });
    expect(result.effects.at(-1)).toEqual({ type: "terminate-child" });
    expect(result.errors).toContain("protocol-state");
  });

  it("sends abort before termination on parent abort [FR-041]", () => {
    const result = run([
      { type: "frame", frame: requestFrame(dialog("r")) },
      { type: "parent-abort" },
    ]);
    expect(result.state).toMatchObject({ pending: [], settled: true });
    expect(result.effects.slice(-2)).toEqual([{ type: "send-abort" }, { type: "terminate-child" }]);
  });

  it("makes every post-settlement event a no-op [FR-042]", () => {
    const settled = { seenRequestIds: [id("old")], pending: [], settled: true } as const;
    for (const event of [
      { type: "child-exited" },
      { type: "parent-abort" },
      { type: "frame", frame: requestFrame(dialog("new")) },
      { type: "answer", id: id("old"), answer: { method: "input", value: "x" } },
    ] as const) {
      expect(relayStep(settled, event)).toEqual({ state: settled, effects: [], errors: [] });
    }
  });

  it("is immutable and deterministic [FR-043]", () => {
    const state = Object.freeze({
      seenRequestIds: Object.freeze([]), pending: Object.freeze([]), settled: false,
    });
    const event = { type: "frame", frame: requestFrame(dialog("r")) } as const;
    expect(() => relayStep(state, event)).not.toThrow();
    expect(relayStep(state, event)).toEqual(relayStep(state, event));
    expect(state).toEqual(initialRelayState);
  });

  it("is deterministic for arbitrary admitted input answers [FR-043]", () => {
    fc.assert(fc.property(
      fc.string({ minLength: 1 }),
      fc.string(),
      (rawId, value) => {
        const request = dialog(rawId);
        const registered = relayStep(initialRelayState, {
          type: "frame", frame: requestFrame(request),
        }).state;
        const event = {
          type: "answer", id: request.id, answer: { method: "input", value },
        } as const;
        expect(relayStep(registered, event)).toEqual(relayStep(registered, event));
      },
    ));
  });
});
