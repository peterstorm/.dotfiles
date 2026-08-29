import { describe, expect, test } from "bun:test";
import { isPlanningBoundary, parseDriverArgs, parseModelEnvironment, splitJsonl } from "./rpc-driver";

const boundary = {
  current_phase: "execute",
  current_wave: 1,
  tasks: [{ id: "T1", status: "pending" }, { id: "T2", status: "pending" }],
  executing_tasks: [],
  wave_gates: {
    "1": { impl_complete: false, reviews_complete: false, tests_passed: null },
  },
};

describe("splitJsonl", () => {
  test("splits on LF only and preserves Unicode line separators", () => {
    const first = splitJsonl({ carry: "" }, '{"text":"a\u2028b"}\n{"n"');
    expect(first.lines).toEqual(['{"text":"a\u2028b"}']);
    expect(first.state.carry).toBe('{"n"');
    const second = splitJsonl(first.state, ":1}\r\n");
    expect(second.lines).toEqual(['{"n":1}']);
    expect(second.state.carry).toBe("");
  });

  test("does not emit an unterminated record", () => {
    expect(splitJsonl({ carry: "partial" }, "-frame")).toEqual({
      lines: [],
      state: { carry: "partial-frame" },
    });
  });
});

describe("isPlanningBoundary", () => {
  test("accepts only pending Wave 1 execution state", () => {
    expect(isPlanningBoundary(boundary)).toBe(true);
  });

  test.each([
    { ...boundary, current_phase: "decompose" },
    { ...boundary, current_wave: 2 },
    { ...boundary, tasks: [] },
    { ...boundary, tasks: [{ id: "T1", status: "executing" }] },
    { ...boundary, executing_tasks: ["T1"] },
    { ...boundary, wave_gates: {} },
    { ...boundary, wave_gates: { "1": { impl_complete: true, reviews_complete: false, tests_passed: null } } },
  ])("rejects non-boundary state %#", (value) => {
    expect(isPlanningBoundary(value)).toBe(false);
  });
});

describe("parseModelEnvironment", () => {
  test("derives exact Pi process metadata from an arm selector", () => {
    expect(parseModelEnvironment("desktop-vllm/glm-v8:max")).toEqual({
      ok: true,
      value: {
        PI_PROVIDER: "desktop-vllm",
        PI_MODEL: "glm-v8",
        PI_REASONING_LEVEL: "max",
      },
    });
  });

  test.each(["glm-v8", "/glm-v8:max", "desktop-vllm/:max", "desktop-vllm/glm-v8:future"])(
    "rejects malformed selector %s",
    (selector) => expect(parseModelEnvironment(selector).ok).toBe(false),
  );
});

describe("parseDriverArgs", () => {
  const required = [
    "--worktree", "/tmp/worktree",
    "--run-dir", "/tmp/run",
    "--model", "desktop-vllm/example:max",
    "--prompt", "/loom Read /tmp/task.md",
  ];

  test("parses a complete invocation with a bounded default timeout", () => {
    const parsed = parseDriverArgs(required);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) expect(parsed.value.timeoutMinutes).toBe(240);
  });

  test.each([
    [...required, "--unknown", "value"],
    required.slice(0, -2),
    [...required, "--timeout-minutes", "0"],
    [...required, "--timeout-minutes", "1.5"],
    [...required, "--model", "duplicate"],
  ])("rejects malformed invocation %#", (args) => {
    expect(parseDriverArgs(args).ok).toBe(false);
  });
});
