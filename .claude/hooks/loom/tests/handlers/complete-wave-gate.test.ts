import { describe, it, expect } from "vitest";
import {
  checkTestEvidence,
  checkNewTests,
  checkReviews,
  checkSpecAlignment,
  checkCriticalFindings,
  computeNextWave,
} from "../../src/handlers/helpers/complete-wave-gate";
import type { Task, TaskGraph } from "../../src/types";

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

describe("checkSpecAlignment (pure)", () => {
  const mkState = (overrides: Partial<TaskGraph> = {}): TaskGraph => ({
    current_phase: "execute",
    phase_artifacts: {},
    skipped_phases: [],
    spec_file: null,
    plan_file: null,
    tasks: [],
    wave_gates: {},
    ...overrides,
  });

  it("passes when no spec-check data", () => {
    const result = checkSpecAlignment(mkState(), 1);
    expect(result.passed).toBe(true);
    expect(result.message).toContain("skipped");
  });

  it("fails when spec-check for different wave", () => {
    const state = mkState({
      spec_check: { wave: 1, run_at: "", verdict: "pass" },
    });
    const result = checkSpecAlignment(state, 2);
    expect(result.passed).toBe(false);
    expect(result.message).toContain("wave 1");
    expect(result.message).toContain("not 2");
  });

  it("passes when spec-check matches wave with no criticals", () => {
    const state = mkState({
      spec_check: { wave: 2, run_at: "", verdict: "pass", critical_count: 0 },
    });
    const result = checkSpecAlignment(state, 2);
    expect(result.passed).toBe(true);
  });

  it("fails when spec-check has critical findings", () => {
    const state = mkState({
      spec_check: { wave: 1, run_at: "", verdict: "fail", critical_count: 2, critical_findings: ["drift", "missing"] },
    });
    const result = checkSpecAlignment(state, 1);
    expect(result.passed).toBe(false);
    expect(result.message).toContain("2 critical");
  });
});

describe("computeNextWave (pure)", () => {
  const mkTask = (wave: number): Task => ({
    ...baseTask,
    id: `T${wave}`,
    wave,
  });

  it("computes next wave from contiguous waves", () => {
    expect(computeNextWave([mkTask(1), mkTask(2), mkTask(3)], 1)).toBe(2);
    expect(computeNextWave([mkTask(1), mkTask(2), mkTask(3)], 2)).toBe(3);
  });

  it("computes next wave from non-contiguous waves", () => {
    expect(computeNextWave([mkTask(1), mkTask(3), mkTask(5)], 1)).toBe(3);
    expect(computeNextWave([mkTask(1), mkTask(3), mkTask(5)], 3)).toBe(5);
  });

  it("returns null when no next wave", () => {
    expect(computeNextWave([mkTask(1), mkTask(2)], 2)).toBeNull();
    expect(computeNextWave([mkTask(1)], 1)).toBeNull();
  });

  it("returns null for empty tasks", () => {
    expect(computeNextWave([], 1)).toBeNull();
  });
});
