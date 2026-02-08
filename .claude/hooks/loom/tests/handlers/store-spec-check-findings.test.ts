import { describe, it, expect } from "vitest";
import { parseSpecCheckOutput } from "../../src/handlers/subagent-stop/store-spec-check-findings";

describe("parseSpecCheckOutput (pure)", () => {
  it("parses all severity levels", () => {
    const output = [
      "CRITICAL: Missing authentication on /api/admin",
      "HIGH: No rate limiting on public endpoints",
      "MEDIUM: Inconsistent error response format",
      "SPEC_CHECK_CRITICAL_COUNT: 1",
      "SPEC_CHECK_HIGH_COUNT: 1",
      "SPEC_CHECK_VERDICT: BLOCKED",
      "SPEC_CHECK_WAVE: 2",
    ].join("\n");

    const result = parseSpecCheckOutput(output);
    expect(result.critical).toEqual(["Missing authentication on /api/admin"]);
    expect(result.high).toEqual(["No rate limiting on public endpoints"]);
    expect(result.medium).toEqual(["Inconsistent error response format"]);
    expect(result.criticalCount).toBe(1);
    expect(result.highCount).toBe(1);
    expect(result.verdict).toBe("BLOCKED");
    expect(result.wave).toBe(2);
  });

  it("handles zero findings", () => {
    const output = "SPEC_CHECK_CRITICAL_COUNT: 0\nSPEC_CHECK_HIGH_COUNT: 0\nSPEC_CHECK_VERDICT: PASSED";
    const result = parseSpecCheckOutput(output);
    expect(result.critical).toEqual([]);
    expect(result.criticalCount).toBe(0);
    expect(result.verdict).toBe("PASSED");
  });

  it("returns null counts when markers missing", () => {
    const result = parseSpecCheckOutput("no markers");
    expect(result.criticalCount).toBeNull();
    expect(result.highCount).toBeNull();
    expect(result.verdict).toBeNull();
  });

  it("extracts multiple findings per severity", () => {
    const output = [
      "CRITICAL: Issue 1",
      "CRITICAL: Issue 2",
      "HIGH: Issue 3",
      "HIGH: Issue 4",
      "HIGH: Issue 5",
    ].join("\n");

    const result = parseSpecCheckOutput(output);
    expect(result.critical).toHaveLength(2);
    expect(result.high).toHaveLength(3);
  });
});
