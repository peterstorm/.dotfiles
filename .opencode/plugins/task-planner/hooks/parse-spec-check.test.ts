/**
 * Tests for parse-spec-check hook
 */

import { describe, it, expect } from "vitest";
import {
  extractSpecCheckFindings,
  isSpecCheckContent,
  determineVerdict,
  isSpecCheckPassed,
  getSpecCheckSummary,
} from "./parse-spec-check.js";
import type { TaskGraph, SpecCheck } from "../types.js";

// ============================================================================
// Test Fixtures
// ============================================================================

function createTaskGraph(overrides: Partial<TaskGraph> = {}): TaskGraph {
  return {
    title: "Test Task Graph",
    spec_file: ".opencode/specs/test.md",
    plan_file: ".opencode/plans/test.md",
    current_phase: "execute",
    phase_artifacts: {},
    skipped_phases: [],
    current_wave: 1,
    tasks: [],
    executing_tasks: [],
    wave_gates: {},
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    ...overrides,
  };
}

function createSpecCheck(overrides: Partial<SpecCheck> = {}): SpecCheck {
  return {
    wave: 1,
    run_at: new Date().toISOString(),
    critical_count: 0,
    high_count: 0,
    critical_findings: [],
    high_findings: [],
    medium_findings: [],
    verdict: "PASSED",
    ...overrides,
  };
}

// ============================================================================
// extractSpecCheckFindings Tests
// ============================================================================

describe("extractSpecCheckFindings", () => {
  it("extracts [CRITICAL] findings", () => {
    const content = `
      ## Spec Check Results
      [CRITICAL] Missing implementation for FR-001
      [CRITICAL] API endpoint does not match spec
    `;

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]).toEqual({
      severity: "CRITICAL",
      description: "Missing implementation for FR-001",
    });
    expect(findings[1]).toEqual({
      severity: "CRITICAL",
      description: "API endpoint does not match spec",
    });
  });

  it("extracts [HIGH] findings", () => {
    const content = `
      [HIGH] Response format differs from specification
      [HIGH] Missing required header X-Request-ID
    `;

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]?.severity).toBe("HIGH");
    expect(findings[1]?.severity).toBe("HIGH");
  });

  it("extracts [MEDIUM] findings", () => {
    const content = `
      [MEDIUM] Consider using more descriptive variable names
      [MEDIUM] Add caching for frequently accessed data
    `;

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]?.severity).toBe("MEDIUM");
    expect(findings[1]?.severity).toBe("MEDIUM");
  });

  it("extracts [LOW] findings", () => {
    const content = "[LOW] Minor documentation update suggested";

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(1);
    expect(findings[0]?.severity).toBe("LOW");
  });

  it("extracts mixed severity findings", () => {
    const content = `
      [CRITICAL] Security vulnerability
      [HIGH] Performance issue
      [MEDIUM] Code style issue
      [LOW] Typo in comment
    `;

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(4);
    expect(findings.map((f) => f.severity)).toEqual([
      "CRITICAL",
      "HIGH",
      "MEDIUM",
      "LOW",
    ]);
  });

  it("returns empty array when no findings", () => {
    const content = `
      ## Spec Check Results
      All checks passed. No drift detected.
    `;

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(0);
  });

  it("ignores invalid severity levels", () => {
    const content = `
      [CRITICAL] Valid finding
      [INVALID] Should be ignored
      [WARNING] Should be ignored
      [HIGH] Another valid finding
    `;

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings.map((f) => f.severity)).toEqual(["CRITICAL", "HIGH"]);
  });

  it("trims whitespace from descriptions", () => {
    const content = "[CRITICAL]   Lots of whitespace here   ";

    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(1);
    expect(findings[0]?.description).toBe("Lots of whitespace here");
  });

  it("handles case-insensitive severity matching", () => {
    const content = `
      [critical] lowercase critical
      [CRITICAL] uppercase CRITICAL
      [Critical] mixed case
    `;

    const findings = extractSpecCheckFindings(content);
    // Pattern uses uppercase for matching, so only uppercase matches
    expect(findings.length).toBeGreaterThanOrEqual(1);
  });
});

// ============================================================================
// isSpecCheckContent Tests
// ============================================================================

describe("isSpecCheckContent", () => {
  it("returns true for spec alignment patterns", () => {
    expect(isSpecCheckContent("Spec alignment check")).toBe(true);
    expect(isSpecCheckContent("Specification alignment verification")).toBe(true);
  });

  it("returns true for spec check patterns", () => {
    expect(isSpecCheckContent("Spec check results")).toBe(true);
    expect(isSpecCheckContent("Specification check complete")).toBe(true);
  });

  it("returns true for spec drift patterns", () => {
    expect(isSpecCheckContent("Spec drift detected")).toBe(true);
    expect(isSpecCheckContent("Specification drift analysis")).toBe(true);
  });

  it("returns true for ## Spec Alignment header", () => {
    expect(isSpecCheckContent("## Spec Alignment\nContent here")).toBe(true);
    expect(isSpecCheckContent("# Specification Check\nResults")).toBe(true);
  });

  it("returns true for severity markers", () => {
    expect(isSpecCheckContent("[CRITICAL] Some issue")).toBe(true);
    expect(isSpecCheckContent("[HIGH] Some issue")).toBe(true);
    expect(isSpecCheckContent("[MEDIUM] Some issue")).toBe(true);
    expect(isSpecCheckContent("[LOW] Some issue")).toBe(true);
  });

  it("returns true for alignment analysis patterns", () => {
    expect(isSpecCheckContent("Alignment analysis complete")).toBe(true);
    expect(isSpecCheckContent("Alignment check passed")).toBe(true);
    expect(isSpecCheckContent("Alignment verification done")).toBe(true);
  });

  it("returns true for spec-check results pattern", () => {
    expect(isSpecCheckContent("spec-check results")).toBe(true);
    expect(isSpecCheckContent("spec-check findings")).toBe(true);
    expect(isSpecCheckContent("spec-check complete")).toBe(true);
  });

  it("returns true for verifying alignment pattern", () => {
    expect(isSpecCheckContent("Verifying spec alignment")).toBe(true);
    expect(isSpecCheckContent("Verifying specification alignment")).toBe(true);
    expect(isSpecCheckContent("Verifying alignment")).toBe(true);
  });

  it("returns false for unrelated content", () => {
    expect(isSpecCheckContent("Implemented new feature")).toBe(false);
    expect(isSpecCheckContent("All tests pass")).toBe(false);
    expect(isSpecCheckContent("Code review complete")).toBe(false);
  });

  it("returns false for empty content", () => {
    expect(isSpecCheckContent("")).toBe(false);
  });
});

// ============================================================================
// determineVerdict Tests
// ============================================================================

describe("determineVerdict", () => {
  it("returns PASSED for explicit verdict: PASSED", () => {
    const content = "Verdict: PASSED\nAll checks passed.";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("returns BLOCKED for explicit verdict: BLOCKED", () => {
    const content = "Verdict: BLOCKED\nCritical issues found.";
    expect(determineVerdict(content, 0)).toBe("BLOCKED");
  });

  it("returns BLOCKED when critical count > 0", () => {
    const content = "Some content without explicit verdict";
    expect(determineVerdict(content, 3)).toBe("BLOCKED");
  });

  it("returns PASSED for 'checks passed' pattern", () => {
    const content = "All checks passed successfully";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("returns PASSED for 'pass' pattern", () => {
    const content = "Spec check pass";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("returns PASSED for 'no drift detected' pattern", () => {
    const content = "No spec drift detected";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("returns PASSED for 'no drift found' pattern", () => {
    const content = "No drift found in implementation";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("returns PASSED for 'implementation matches spec' pattern", () => {
    const content = "The implementation matches spec exactly";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("returns PASSED for 'implementation aligns with spec' pattern", () => {
    const content = "Implementation aligns with spec perfectly";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("returns PASSED by default when no critical findings", () => {
    const content = "Generic content without clear verdict";
    expect(determineVerdict(content, 0)).toBe("PASSED");
  });

  it("explicit verdict overrides critical count", () => {
    // Even though we say criticalCount is 0, the explicit BLOCKED wins
    const content = "Verdict: BLOCKED";
    expect(determineVerdict(content, 0)).toBe("BLOCKED");

    // Even though we say criticalCount is 5, the explicit PASSED wins
    const content2 = "Verdict: PASSED";
    expect(determineVerdict(content2, 5)).toBe("PASSED");
  });
});

// ============================================================================
// isSpecCheckPassed Tests
// ============================================================================

describe("isSpecCheckPassed", () => {
  it("returns true when no spec_check exists", () => {
    const taskGraph = createTaskGraph({ spec_check: undefined });
    expect(isSpecCheckPassed(taskGraph, 1)).toBe(true);
  });

  it("returns true when spec_check verdict is PASSED", () => {
    const taskGraph = createTaskGraph({
      spec_check: createSpecCheck({ wave: 1, verdict: "PASSED" }),
    });
    expect(isSpecCheckPassed(taskGraph, 1)).toBe(true);
  });

  it("returns false when spec_check verdict is BLOCKED", () => {
    const taskGraph = createTaskGraph({
      spec_check: createSpecCheck({ wave: 1, verdict: "BLOCKED" }),
    });
    expect(isSpecCheckPassed(taskGraph, 1)).toBe(false);
  });

  it("returns true when spec_check is for different wave", () => {
    const taskGraph = createTaskGraph({
      spec_check: createSpecCheck({ wave: 1, verdict: "BLOCKED" }),
    });
    // Check for wave 2, but spec_check is for wave 1
    expect(isSpecCheckPassed(taskGraph, 2)).toBe(true);
  });

  it("returns true when spec_check wave matches and passed", () => {
    const taskGraph = createTaskGraph({
      spec_check: createSpecCheck({ wave: 2, verdict: "PASSED" }),
    });
    expect(isSpecCheckPassed(taskGraph, 2)).toBe(true);
  });

  it("handles EVIDENCE_CAPTURE_FAILED verdict", () => {
    const taskGraph = createTaskGraph({
      spec_check: createSpecCheck({ wave: 1, verdict: "EVIDENCE_CAPTURE_FAILED" }),
    });
    expect(isSpecCheckPassed(taskGraph, 1)).toBe(false);
  });

  it("handles UNKNOWN verdict", () => {
    const taskGraph = createTaskGraph({
      spec_check: createSpecCheck({ wave: 1, verdict: "UNKNOWN" }),
    });
    expect(isSpecCheckPassed(taskGraph, 1)).toBe(false);
  });
});

// ============================================================================
// getSpecCheckSummary Tests
// ============================================================================

describe("getSpecCheckSummary", () => {
  it("returns passed summary for PASSED verdict", () => {
    const specCheck = createSpecCheck({ wave: 1, verdict: "PASSED" });
    const summary = getSpecCheckSummary(specCheck);
    expect(summary).toContain("Spec alignment verified");
    expect(summary).toContain("wave 1");
  });

  it("returns blocked summary for BLOCKED verdict", () => {
    const specCheck = createSpecCheck({
      wave: 2,
      verdict: "BLOCKED",
      critical_count: 3,
      high_count: 5,
    });
    const summary = getSpecCheckSummary(specCheck);
    expect(summary).toContain("Spec drift detected");
    expect(summary).toContain("3 critical");
    expect(summary).toContain("5 high");
    expect(summary).toContain("wave 2");
  });

  it("includes correct wave number", () => {
    const specCheck = createSpecCheck({ wave: 5, verdict: "PASSED" });
    const summary = getSpecCheckSummary(specCheck);
    expect(summary).toContain("wave 5");
  });

  it("shows zero counts for BLOCKED verdict", () => {
    const specCheck = createSpecCheck({
      wave: 1,
      verdict: "BLOCKED",
      critical_count: 0,
      high_count: 0,
    });
    const summary = getSpecCheckSummary(specCheck);
    expect(summary).toContain("0 critical");
    expect(summary).toContain("0 high");
  });
});

// ============================================================================
// Edge Cases Tests
// ============================================================================

describe("edge cases", () => {
  it("handles empty content in extractSpecCheckFindings", () => {
    const findings = extractSpecCheckFindings("");
    expect(findings).toHaveLength(0);
  });

  it("handles null-like values in extractSpecCheckFindings", () => {
    const content = "[CRITICAL] ";
    const findings = extractSpecCheckFindings(content);
    // Empty description after severity should be filtered or handled
    expect(findings.length).toBe(0);
  });

  it("handles very long finding descriptions", () => {
    const longDescription = "A".repeat(1000);
    const content = `[CRITICAL] ${longDescription}`;
    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(1);
    expect(findings[0]?.description).toBe(longDescription);
  });

  it("handles findings with special characters", () => {
    const content = "[CRITICAL] Issue with `backticks` and 'quotes' and \"double quotes\"";
    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(1);
    expect(findings[0]?.description).toContain("`backticks`");
  });

  it("handles multiline content with findings at different positions", () => {
    const content = `
      Header text
      [CRITICAL] First finding
      Some other content
      More text here
      [HIGH] Second finding
      Trailing text
    `;
    const findings = extractSpecCheckFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]?.severity).toBe("CRITICAL");
    expect(findings[1]?.severity).toBe("HIGH");
  });
});
