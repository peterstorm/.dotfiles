import { describe, it, expect } from "vitest";
import {
  checkTestEvidence,
  checkNewTests,
  checkReviews,
  checkCriticalFindings,
} from "../../src/handlers/helpers/complete-wave-gate";
import type { Task } from "../../src/types";

const baseTask: Task = {
  id: "T1",
  description: "test",
  agent: "code-implementer-agent",
  wave: 1,
  status: "implemented",
  depends_on: [],
  tests_passed: true,
  test_evidence: "vitest: Tests 5 passed",
  new_tests_written: true,
  new_test_evidence: "1 new test, 1 assertion",
  review_status: "passed",
  critical_findings: [],
  advisory_findings: [],
};

describe("checkTestEvidence (pure)", () => {
  it("passes when all tasks have test evidence", () => {
    const result = checkTestEvidence([baseTask]);
    expect(result.passed).toBe(true);
  });

  it("fails when task missing test evidence", () => {
    const result = checkTestEvidence([{ ...baseTask, tests_passed: false }]);
    expect(result.passed).toBe(false);
    expect(result.message).toContain("FAILED");
    expect(result.message).toContain("T1");
  });
});

describe("checkNewTests (pure)", () => {
  it("passes when all tasks have new tests", () => {
    const result = checkNewTests([baseTask]);
    expect(result.passed).toBe(true);
  });

  it("passes when task has new_tests_required=false", () => {
    const task = { ...baseTask, new_tests_required: false, new_tests_written: false };
    const result = checkNewTests([task]);
    expect(result.passed).toBe(true);
  });

  it("fails when task missing new tests", () => {
    const task = { ...baseTask, new_tests_written: false, new_tests_required: undefined };
    const result = checkNewTests([task]);
    expect(result.passed).toBe(false);
  });
});

describe("checkReviews (pure)", () => {
  it("passes when all tasks reviewed", () => {
    const result = checkReviews([baseTask]);
    expect(result.passed).toBe(true);
  });

  it("passes with blocked review (still reviewed)", () => {
    const result = checkReviews([{ ...baseTask, review_status: "blocked" }]);
    expect(result.passed).toBe(true);
  });

  it("fails for pending review", () => {
    const result = checkReviews([{ ...baseTask, review_status: "pending" }]);
    expect(result.passed).toBe(false);
    expect(result.message).toContain("Unreviewed");
  });

  it("reports evidence_capture_failed separately", () => {
    const result = checkReviews([{ ...baseTask, review_status: "evidence_capture_failed" }]);
    expect(result.passed).toBe(false);
    expect(result.message).toContain("Evidence capture failed");
  });
});

describe("checkCriticalFindings (pure)", () => {
  it("passes with no critical findings", () => {
    const result = checkCriticalFindings([baseTask]);
    expect(result.passed).toBe(true);
  });

  it("fails with critical findings", () => {
    const task = { ...baseTask, critical_findings: ["SQL injection", "XSS"] };
    const result = checkCriticalFindings([task]);
    expect(result.passed).toBe(false);
    expect(result.message).toContain("2 critical");
  });

  it("handles undefined critical_findings", () => {
    const task = { ...baseTask, critical_findings: undefined };
    const result = checkCriticalFindings([task]);
    expect(result.passed).toBe(true);
  });
});
