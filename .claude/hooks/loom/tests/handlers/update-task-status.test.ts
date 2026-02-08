import { describe, it, expect } from "vitest";
import { extractTestEvidence, analyzeNewTests } from "../../src/handlers/subagent-stop/update-task-status";

describe("extractTestEvidence (pure)", () => {
  it("detects Maven BUILD SUCCESS", () => {
    const output = "BUILD SUCCESS\nTests run: 42, Failures: 0, Errors: 0";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(true);
    expect(result.evidence).toContain("maven");
    expect(result.evidence).toContain("Tests run: 42");
  });

  it("strips markdown bold from Maven output", () => {
    const output = "**BUILD SUCCESS**\n**Tests run: 5, Failures: 0, Errors: 0**";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(true);
    expect(result.evidence).toContain("maven");
  });

  it("rejects Maven with failures", () => {
    const output = "BUILD SUCCESS\nTests run: 10, Failures: 2, Errors: 0";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(false);
  });

  it("detects Node/Mocha passing", () => {
    const output = "  15 passing (2s)";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(true);
    expect(result.evidence).toContain("node");
  });

  it("rejects Node with failing tests", () => {
    const output = "  10 passing\n  3 failing";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(false);
  });

  it("detects Vitest passing", () => {
    const output = "Tests  36 passed (36)\n Test Files  3 passed (3)";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(true);
    expect(result.evidence).toContain("vitest");
  });

  it("rejects Vitest with failed", () => {
    const output = "Tests  30 passed\n Tests  2 failed";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(false);
  });

  it("detects pytest passing", () => {
    const output = "===== 8 passed in 0.5s =====";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(true);
    expect(result.evidence).toContain("pytest");
  });

  it("rejects pytest with failures", () => {
    const output = "===== 6 passed, 2 failed =====";
    const result = extractTestEvidence(output);
    expect(result.passed).toBe(false);
  });

  it("returns false for no test output", () => {
    const result = extractTestEvidence("just some code output");
    expect(result.passed).toBe(false);
    expect(result.evidence).toBe("");
  });
});

describe("analyzeNewTests (pure)", () => {
  it("detects Java @Test methods with assertions", () => {
    const diff = [
      "+    @Test",
      "+    void shouldWork() {",
      "+    assertThat(result).isEqualTo(42);",
    ].join("\n");
    const result = analyzeNewTests(diff, undefined);
    expect(result.written).toBe(true);
    expect(result.evidence).toContain("1 new test");
    expect(result.evidence).toContain("assertion");
  });

  it("rejects test stubs with no assertions", () => {
    const diff = [
      "+    @Test",
      "+    void stubTest() {",
      "+    }",
    ].join("\n");
    const result = analyzeNewTests(diff, undefined);
    expect(result.written).toBe(false);
    expect(result.evidence).toContain("0 assertions");
  });

  it("skips when new_tests_required=false", () => {
    const diff = "+    @Test\n+    assertThat(x).isTrue();";
    const result = analyzeNewTests(diff, false);
    expect(result.written).toBe(false);
    expect(result.evidence).toContain("skipped");
  });

  it("detects TypeScript tests with expect()", () => {
    const diff = [
      '+  it("works", () => {',
      "+    expect(result).toBe(42);",
    ].join("\n");
    const result = analyzeNewTests(diff, undefined);
    expect(result.written).toBe(true);
    expect(result.evidence).toContain("ts");
  });

  it("returns empty for no tests in diff", () => {
    const diff = "+const x = 42;\n+function foo() {}";
    const result = analyzeNewTests(diff, undefined);
    expect(result.written).toBe(false);
    expect(result.evidence).toBe("");
  });
});
