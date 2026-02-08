import { describe, it, expect } from "vitest";
import { parseMachineSummary, parseLegacyFindings } from "../../src/handlers/subagent-stop/store-reviewer-findings";

describe("parseMachineSummary (pure)", () => {
  it("parses structured Machine Summary block", () => {
    const output = [
      "Some preamble",
      "### Machine Summary",
      "CRITICAL_COUNT: 2",
      "ADVISORY_COUNT: 1",
      "CRITICAL: SQL injection in query builder",
      "CRITICAL: Missing auth check on endpoint",
      "ADVISORY: Consider extracting validation",
      "",
      "### Other section",
    ].join("\n");

    const result = parseMachineSummary(output);
    expect(result).not.toBeNull();
    expect(result!.criticalCount).toBe(2);
    expect(result!.critical).toEqual([
      "SQL injection in query builder",
      "Missing auth check on endpoint",
    ]);
    expect(result!.advisory).toEqual(["Consider extracting validation"]);
  });

  it("returns null when no Machine Summary block", () => {
    expect(parseMachineSummary("just plain text")).toBeNull();
  });

  it("handles zero findings", () => {
    const output = "### Machine Summary\nCRITICAL_COUNT: 0\nADVISORY_COUNT: 0\n\n";
    const result = parseMachineSummary(output);
    expect(result).not.toBeNull();
    expect(result!.criticalCount).toBe(0);
    expect(result!.critical).toEqual([]);
  });
});

describe("parseLegacyFindings (pure)", () => {
  it("parses Critical/Advisory sections", () => {
    const output = [
      "### Critical Findings",
      "- **XSS vulnerability in template**",
      "- Missing input sanitization",
      "### Advisory Findings",
      "- Consider using parameterized queries",
      "### Other",
    ].join("\n");

    const result = parseLegacyFindings(output);
    expect(result.critical.length).toBe(2);
    expect(result.advisory.length).toBe(1);
  });

  it("skips None entries", () => {
    const output = [
      "### Critical Findings",
      "- None",
      "### Advisory Findings",
      "- None",
      "### Other",
    ].join("\n");

    const result = parseLegacyFindings(output);
    expect(result.critical).toEqual([]);
    expect(result.advisory).toEqual([]);
  });

  it("extracts CRITICAL_COUNT from body", () => {
    const output = "blah\nCRITICAL_COUNT: 5\nblah";
    const result = parseLegacyFindings(output);
    expect(result.criticalCount).toBe(5);
  });

  it("returns null criticalCount when marker missing", () => {
    const result = parseLegacyFindings("no markers here");
    expect(result.criticalCount).toBeNull();
  });
});
