/**
 * HIDDEN ACCEPTANCE SUITE — never place this file inside a benchmark worktree.
 *
 * It is copied in only after an arm has finished and its commit is recorded.
 * Every test names the requirement it enforces; a test that cannot cite an
 * FR from frozen/spec.md does not belong here.
 */
import { describe, expect, it } from "vitest";
import {
  decodeChunk,
  emptyDecodeState,
  initialRelayState,
  parseRequestId,
  relayStep,
} from "../../src/core/ui-relay";
import type {
  ChildFrame,
  RelayEffect,
  RelayState,
  RequestId,
  UiRequest,
} from "../../src/core/ui-relay-types";

// --- helpers ---------------------------------------------------------------

const id = (raw: string): RequestId => {
  const parsed = parseRequestId(raw);
  if (!parsed.ok) throw new Error(`test fixture: ${raw} is not a valid id`);
  return parsed.value;
};

const deepFreeze = <T>(value: T): T => {
  if (value && typeof value === "object") {
    Object.freeze(value);
    for (const key of Object.getOwnPropertyNames(value)) {
      deepFreeze((value as Record<string, unknown>)[key]);
    }
  }
  return value;
};

const line = (o: unknown) => `${JSON.stringify(o)}\n`;

const selectWire = (rid: string, options: string[] = ["a", "b"]) =>
  line({ method: "select", id: rid, prompt: "pick", options });
const confirmWire = (rid: string) => line({ method: "confirm", id: rid, prompt: "sure?" });

const decodeOne = (chunk: string) => decodeChunk(emptyDecodeState, chunk);

const kinds = (out: { errors: readonly { kind: string }[] }) => out.errors.map((e) => e.kind);

/** Drive the machine from a fresh state through a list of events. */
const run = (events: Parameters<typeof relayStep>[1][]): { state: RelayState; effects: RelayEffect[] } => {
  let state = initialRelayState;
  const effects: RelayEffect[] = [];
  for (const event of events) {
    const step = relayStep(state, event);
    state = step.state;
    effects.push(...step.effects);
  }
  return { state, effects };
};

const requestFrame = (request: UiRequest): ChildFrame => ({ type: "ui-request", request });

const selectRequest = (rid: string, options: readonly string[] = ["a", "b"]): UiRequest => ({
  method: "select",
  id: id(rid),
  prompt: "pick",
  options,
});

// --- ids -------------------------------------------------------------------

describe("parseRequestId", () => {
  it("accepts a non-whitespace string [FR-001]", () => {
    const parsed = parseRequestId("req-1");
    expect(parsed.ok).toBe(true);
    if (parsed.ok) expect(parsed.value).toBe("req-1");
  });

  it.each([["", "empty"], ["   ", "whitespace"], ["\t\n", "control whitespace"]])(
    "rejects %s [FR-002]",
    (raw) => {
      const parsed = parseRequestId(raw);
      expect(parsed.ok).toBe(false);
      if (!parsed.ok) expect(parsed.error.kind).toBe("malformed-frame");
    },
  );

  it.each([[42], [null], [undefined], [{}], [["a"]]])("rejects non-string %p [FR-002]", (raw) => {
    expect(parseRequestId(raw).ok).toBe(false);
  });
});

// --- decoding --------------------------------------------------------------

describe("decodeChunk", () => {
  it("decodes one complete line and leaves no carry [FR-010]", () => {
    const out = decodeOne(confirmWire("r1"));
    expect(out.errors).toEqual([]);
    expect(out.state.carry).toBe("");
    expect(out.frames).toHaveLength(1);
    expect(out.frames[0]).toMatchObject({
      type: "ui-request",
      request: { method: "confirm", id: "r1", prompt: "sure?" },
    });
  });

  it("preserves arrival order across multiple lines in one chunk [FR-010]", () => {
    const out = decodeOne(confirmWire("r1") + confirmWire("r2") + confirmWire("r3"));
    expect(out.frames).toHaveLength(3);
    expect(out.frames.map((f) => (f.type === "ui-request" ? f.request.id : null))).toEqual([
      "r1",
      "r2",
      "r3",
    ]);
  });

  it("holds a trailing partial line in carry and emits no frame [FR-011]", () => {
    const whole = confirmWire("r1");
    const out = decodeChunk(emptyDecodeState, whole.slice(0, 12));
    expect(out.frames).toEqual([]);
    expect(out.errors).toEqual([]);
    expect(out.state.carry).toBe(whole.slice(0, 12));
  });

  it("reassembles a line split across three chunks [FR-011]", () => {
    const whole = selectWire("r1");
    const a = decodeChunk(emptyDecodeState, whole.slice(0, 10));
    const b = decodeChunk(a.state, whole.slice(10, 25));
    const c = decodeChunk(b.state, whole.slice(25));
    expect(a.frames.length + b.frames.length).toBe(0);
    expect(c.frames).toHaveLength(1);
    expect(c.state.carry).toBe("");
  });

  it("reports malformed JSON but keeps decoding later lines in the chunk [FR-012]", () => {
    const out = decodeOne(`{not json\n${confirmWire("r2")}`);
    expect(kinds(out)).toContain("malformed-frame");
    expect(out.frames).toHaveLength(1);
    expect(out.frames[0]).toMatchObject({ request: { id: "r2" } });
  });

  it("treats a good line before a bad one as decoded [FR-012]", () => {
    const out = decodeOne(`${confirmWire("r1")}{oops\n`);
    expect(out.frames).toHaveLength(1);
    expect(kinds(out)).toEqual(["malformed-frame"]);
  });

  it("does not strip a trailing CR; CRLF input is malformed [FR-013]", () => {
    const out = decodeOne(confirmWire("r1").replace("\n", "\r\n"));
    expect(out.frames).toEqual([]);
    expect(kinds(out)).toEqual(["malformed-frame"]);
  });

  it("treats an empty line as a protocol error [FR-014]", () => {
    const out = decodeOne("\n");
    expect(out.frames).toEqual([]);
    expect(kinds(out)).toEqual(["malformed-frame"]);
  });

  it("rejects an unknown method [FR-015]", () => {
    const out = decodeOne(line({ method: "teleport", id: "r1" }));
    expect(out.frames).toEqual([]);
    expect(kinds(out)).toEqual(["unknown-method"]);
  });

  it.each([["spawn"], ["subagent"], ["task"]])(
    "rejects delegation method %s as recursive-delegation [FR-016]",
    (method) => {
      const out = decodeOne(line({ method, id: "r1", prompt: "p" }));
      expect(out.frames).toEqual([]);
      expect(kinds(out)).toEqual(["recursive-delegation"]);
    },
  );

  it("decodes progress and done frames [FR-015]", () => {
    const out = decodeOne(line({ method: "progress", text: "working" }) + line({ method: "done" }));
    expect(out.errors).toEqual([]);
    expect(out.frames).toEqual([
      { type: "progress", text: "working" },
      { type: "done" },
    ]);
  });

  it.each([
    [{ method: "select", id: "r1", prompt: "p" }, "select without options"],
    [{ method: "select", id: "r1", options: ["a"] }, "select without prompt"],
    [{ method: "confirm", prompt: "p" }, "confirm without id"],
    [{ method: "input", id: "r1" }, "input without prompt"],
    [{ method: "editor", id: "r1", prompt: "p" }, "editor without initial"],
    [{ method: "progress" }, "progress without text"],
    [{ method: "select", id: "r1", prompt: "p", options: "a" }, "options not an array"],
    [{ method: "confirm", id: "r1", prompt: 7 }, "prompt not a string"],
    [{ method: "confirm", id: "", prompt: "p" }, "empty id"],
  ])("rejects %j — %s [FR-017]", (wire, _label) => {
    const out = decodeOne(line(wire));
    expect(out.frames).toEqual([]);
    expect(kinds(out)).toEqual(["malformed-frame"]);
  });

  it("rejects a select with no options [FR-018]", () => {
    const out = decodeOne(selectWire("r1", []));
    expect(out.frames).toEqual([]);
    expect(kinds(out)).toEqual(["malformed-frame"]);
  });

  it("never emits both a frame and an error for one line [FR-019]", () => {
    for (const chunk of ["\n", "{bad\n", line({ method: "nope" }), selectWire("r1", [])]) {
      const out = decodeOne(chunk);
      expect(out.frames.length + out.errors.length).toBe(1);
    }
  });

  it("does not throw on hostile input [FR-019]", () => {
    for (const chunk of ["", "\n\n\n", "null\n", "[]\n", '"str"\n', "123\n", "{}\n"]) {
      expect(() => decodeOne(chunk)).not.toThrow();
    }
  });
});

// --- correlation -----------------------------------------------------------

describe("relayStep", () => {
  it("registers a request and prompts exactly once [FR-030]", () => {
    const step = relayStep(initialRelayState, {
      type: "frame",
      frame: requestFrame(selectRequest("r1")),
    });
    expect(step.errors).toEqual([]);
    expect(step.state.pending.map((p) => p.id)).toEqual(["r1"]);
    expect(step.effects).toEqual([{ type: "prompt-user", request: selectRequest("r1") }]);
  });

  it("rejects a duplicate pending id without re-prompting [FR-031]", () => {
    const first = relayStep(initialRelayState, {
      type: "frame",
      frame: requestFrame(selectRequest("r1")),
    });
    const second = relayStep(first.state, {
      type: "frame",
      frame: requestFrame(selectRequest("r1")),
    });
    expect(kinds(second)).toEqual(["duplicate-request"]);
    expect(second.effects).toEqual([]);
    expect(second.state.pending).toHaveLength(1);
  });

  it("answers a pending request and clears it [FR-032]", () => {
    const { state, effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "answer", id: id("r1"), answer: { method: "select", index: 1 } },
    ]);
    expect(state.pending).toEqual([]);
    expect(effects).toContainEqual({
      type: "send-response",
      id: "r1",
      outcome: { status: "answered", answer: { method: "select", index: 1 } },
    });
  });

  it("rejects an answer of the wrong method and keeps the request pending [FR-033]", () => {
    const first = relayStep(initialRelayState, {
      type: "frame",
      frame: requestFrame(selectRequest("r1")),
    });
    const step = relayStep(first.state, {
      type: "answer",
      id: id("r1"),
      answer: { method: "confirm", accepted: true },
    });
    expect(kinds(step)).toEqual(["response-mismatch"]);
    expect(step.effects).toEqual([]);
    expect(step.state.pending).toHaveLength(1);
  });

  it.each([[-1], [2], [99]])(
    "rejects out-of-range select index %i and keeps it pending [FR-034]",
    (index) => {
      const first = relayStep(initialRelayState, {
        type: "frame",
        frame: requestFrame(selectRequest("r1", ["a", "b"])),
      });
      const step = relayStep(first.state, {
        type: "answer",
        id: id("r1"),
        answer: { method: "select", index },
      });
      expect(kinds(step)).toEqual(["response-mismatch"]);
      expect(step.state.pending).toHaveLength(1);
    },
  );

  it("rejects an answer for an id never seen [FR-035]", () => {
    const step = relayStep(initialRelayState, {
      type: "answer",
      id: id("ghost"),
      answer: { method: "confirm", accepted: true },
    });
    expect(kinds(step)).toEqual(["unknown-request"]);
    expect(step.effects).toEqual([]);
  });

  it("sends exactly one response per request even when answered twice [FR-035]", () => {
    const { effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "answer", id: id("r1"), answer: { method: "select", index: 0 } },
      { type: "answer", id: id("r1"), answer: { method: "select", index: 1 } },
    ]);
    expect(effects.filter((e) => e.type === "send-response")).toHaveLength(1);
  });

  it("does not answer a request that was already cancelled [FR-035]", () => {
    const { effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "cancel", id: id("r1"), reason: "timeout" },
      { type: "answer", id: id("r1"), answer: { method: "select", index: 0 } },
    ]);
    expect(effects.filter((e) => e.type === "send-response")).toHaveLength(1);
  });

  it("cancels with the reason it was given [FR-036]", () => {
    const { state, effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "cancel", id: id("r1"), reason: "timeout" },
    ]);
    expect(state.pending).toEqual([]);
    expect(effects).toContainEqual({
      type: "send-response",
      id: "r1",
      outcome: { status: "cancelled", reason: "timeout" },
    });
  });

  it("cancels every pending request in arrival order on child exit [FR-037]", () => {
    const { state, effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "frame", frame: requestFrame(selectRequest("r2")) },
      { type: "child-exited" },
    ]);
    const responses = effects.filter((e) => e.type === "send-response");
    expect(responses.map((r) => (r.type === "send-response" ? r.id : null))).toEqual(["r1", "r2"]);
    expect(
      responses.every(
        (r) => r.type === "send-response" && r.outcome.status === "cancelled" && r.outcome.reason === "child-exited",
      ),
    ).toBe(true);
    expect(state.closed).toBe(true);
    expect(state.pending).toEqual([]);
  });

  it("cancels pending work and closes the child on parent shutdown [FR-038]", () => {
    const { state, effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "parent-shutdown" },
    ]);
    expect(effects).toContainEqual({
      type: "send-response",
      id: "r1",
      outcome: { status: "cancelled", reason: "parent-shutdown" },
    });
    expect(effects.at(-1)).toEqual({ type: "close-child" });
    expect(state.closed).toBe(true);
  });

  it("cancels stragglers before closing on done [FR-039]", () => {
    const { state, effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "frame", frame: { type: "done" } },
    ]);
    const responseIndex = effects.findIndex((e) => e.type === "send-response");
    const closeIndex = effects.findIndex((e) => e.type === "close-child");
    expect(responseIndex).toBeGreaterThanOrEqual(0);
    expect(closeIndex).toBeGreaterThan(responseIndex);
    expect(state.closed).toBe(true);
  });

  it("surfaces progress without touching pending [FR-040]", () => {
    const { state, effects } = run([
      { type: "frame", frame: requestFrame(selectRequest("r1")) },
      { type: "frame", frame: { type: "progress", text: "working" } },
    ]);
    expect(effects).toContainEqual({ type: "show-progress", text: "working" });
    expect(state.pending).toHaveLength(1);
  });

  it("is a no-op in every terminal state [FR-041]", () => {
    const closed = relayStep(initialRelayState, { type: "frame", frame: { type: "done" } }).state;
    for (const event of [
      { type: "frame", frame: requestFrame(selectRequest("r9")) },
      { type: "answer", id: id("r9"), answer: { method: "select", index: 0 } },
      { type: "cancel", id: id("r9"), reason: "timeout" },
      { type: "child-exited" },
      { type: "parent-shutdown" },
    ] as const) {
      const step = relayStep(closed, event);
      expect(step.effects).toEqual([]);
      expect(step.errors).toEqual([]);
      expect(step.state).toEqual(closed);
    }
  });

  it("does not mutate the state it is given [FR-042]", () => {
    const seeded = relayStep(initialRelayState, {
      type: "frame",
      frame: requestFrame(selectRequest("r1")),
    }).state;
    deepFreeze(seeded);
    expect(() =>
      relayStep(seeded, { type: "answer", id: id("r1"), answer: { method: "select", index: 0 } }),
    ).not.toThrow();
    expect(seeded.pending).toHaveLength(1);
    expect(seeded.closed).toBe(false);
  });

  it("is deterministic in (state, event) [FR-042]", () => {
    const event = { type: "frame", frame: requestFrame(selectRequest("r1")) } as const;
    expect(relayStep(initialRelayState, event)).toEqual(relayStep(initialRelayState, event));
  });
});
