import { describe, it, expect } from "vitest";
import { categorize } from "../../src/handlers/subagent-stop/dispatch";

describe("categorize (pure)", () => {
  it("categorizes phase agents", () => {
    expect(categorize("brainstorm-agent")).toBe("phase");
    expect(categorize("specify-agent")).toBe("phase");
    expect(categorize("clarify-agent")).toBe("phase");
    expect(categorize("architecture-agent")).toBe("phase");
    expect(categorize("decompose-agent")).toBe("phase");
  });

  it("categorizes impl agents", () => {
    expect(categorize("code-implementer-agent")).toBe("impl");
    expect(categorize("java-test-agent")).toBe("impl");
    expect(categorize("ts-test-agent")).toBe("impl");
    expect(categorize("frontend-agent")).toBe("impl");
    expect(categorize("security-agent")).toBe("impl");
    expect(categorize("k8s-agent")).toBe("impl");
    expect(categorize("general-purpose")).toBe("impl");
  });

  it("categorizes review-invoker", () => {
    expect(categorize("review-invoker")).toBe("review");
  });

  it("categorizes spec-check-invoker", () => {
    expect(categorize("spec-check-invoker")).toBe("spec-check");
  });

  it("returns unknown for unrecognized", () => {
    expect(categorize("random-agent")).toBe("unknown");
    expect(categorize("")).toBe("unknown");
  });
});
