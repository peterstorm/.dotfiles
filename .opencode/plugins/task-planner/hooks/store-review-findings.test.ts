/**
 * Tests for store-review-findings hook
 */

import { describe, it, expect } from "vitest";
import {
  extractCriticalFindings,
  extractAdvisoryFindings,
  isReviewContent,
  isReviewPassMessage,
  isReviewAgent,
  countWaveCriticalFindings,
  getBlockedTasks,
  areAllTasksReviewed,
} from "./store-review-findings";
import type { TaskGraph, Task } from "../types";

// ============================================================================
// Test Fixtures
// ============================================================================

function createTask(overrides: Partial<Task> = {}): Task {
  return {
    id: "T1",
    description: "Test task",
    wave: 1,
    status: "pending",
    agent: "code-implementer-agent",
    depends_on: [],
    ...overrides,
  };
}

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

// ============================================================================
// extractCriticalFindings Tests
// ============================================================================

describe("extractCriticalFindings", () => {
  it("extracts CRITICAL: findings", () => {
    const content = `
      CRITICAL: Missing null check in processData function
      CRITICAL: SQL injection vulnerability in query builder
    `;

    const findings = extractCriticalFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]).toBe("Missing null check in processData function");
    expect(findings[1]).toBe("SQL injection vulnerability in query builder");
  });

  it("extracts emoji-prefixed CRITICAL findings", () => {
    const content = `
      Some intro text
      CRITICAL: First issue
      CRITICAL: Second issue
    `;

    const findings = extractCriticalFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]).toBe("First issue");
    expect(findings[1]).toBe("Second issue");
  });

  it("returns empty array when no CRITICAL findings", () => {
    const content = `
      ## Review Summary
      The code looks good. No critical issues found.
      ADVISORY: Consider adding more tests.
    `;

    const findings = extractCriticalFindings(content);
    expect(findings).toHaveLength(0);
  });

  it("handles multiline review content", () => {
    const content = `
      ## Code Review Findings

      ### Critical Issues
      CRITICAL: Memory leak in connection pool - connections are never released
      CRITICAL: Race condition in cache update - multiple threads can corrupt state

      ### Advisory Issues
      ADVISORY: Consider using dependency injection
    `;

    const findings = extractCriticalFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]).toContain("Memory leak");
    expect(findings[1]).toContain("Race condition");
  });

  it("trims whitespace from findings", () => {
    const content = "CRITICAL:   Lots of whitespace   ";

    const findings = extractCriticalFindings(content);
    expect(findings).toHaveLength(1);
    expect(findings[0]).toBe("Lots of whitespace");
  });
});

// ============================================================================
// extractAdvisoryFindings Tests
// ============================================================================

describe("extractAdvisoryFindings", () => {
  it("extracts ADVISORY: findings", () => {
    const content = `
      ADVISORY: Consider adding JSDoc comments
      ADVISORY: Variable naming could be more descriptive
    `;

    const findings = extractAdvisoryFindings(content);
    expect(findings).toHaveLength(2);
    expect(findings[0]).toBe("Consider adding JSDoc comments");
    expect(findings[1]).toBe("Variable naming could be more descriptive");
  });

  it("extracts emoji-prefixed ADVISORY findings", () => {
    const content = `
      ADVISORY: Consider using const instead of let
    `;

    const findings = extractAdvisoryFindings(content);
    expect(findings).toHaveLength(1);
    expect(findings[0]).toBe("Consider using const instead of let");
  });

  it("returns empty array when no ADVISORY findings", () => {
    const content = `
      ## Review Summary
      Code is perfect!
      CRITICAL: Just kidding, this is critical
    `;

    const findings = extractAdvisoryFindings(content);
    expect(findings).toHaveLength(0);
  });

  it("handles mixed CRITICAL and ADVISORY findings", () => {
    const content = `
      CRITICAL: Security issue
      ADVISORY: Style improvement
      CRITICAL: Another security issue
      ADVISORY: Another style improvement
    `;

    const advisoryFindings = extractAdvisoryFindings(content);
    expect(advisoryFindings).toHaveLength(2);
    expect(advisoryFindings[0]).toBe("Style improvement");
    expect(advisoryFindings[1]).toBe("Another style improvement");
  });
});

// ============================================================================
// isReviewContent Tests
// ============================================================================

describe("isReviewContent", () => {
  it("returns true for content with CRITICAL findings", () => {
    const content = "CRITICAL: Something is wrong";
    expect(isReviewContent(content)).toBe(true);
  });

  it("returns true for content with ADVISORY findings", () => {
    const content = "ADVISORY: Consider improving this";
    expect(isReviewContent(content)).toBe(true);
  });

  it("returns true for review pass messages", () => {
    const content = "Review passed - no issues found";
    expect(isReviewContent(content)).toBe(true);
  });

  it("returns true for ## Code Review header", () => {
    const content = "## Code Review\nEverything looks good.";
    expect(isReviewContent(content)).toBe(true);
  });

  it("returns true for # Review header", () => {
    const content = "# Review Summary\nAll checks passed.";
    expect(isReviewContent(content)).toBe(true);
  });

  it("returns true for Review complete message", () => {
    const content = "Review complete - ready to merge";
    expect(isReviewContent(content)).toBe(true);
  });

  it("returns false for unrelated content", () => {
    const content = "Implemented the new feature. All tests pass.";
    expect(isReviewContent(content)).toBe(false);
  });

  it("returns false for empty content", () => {
    expect(isReviewContent("")).toBe(false);
  });
});

// ============================================================================
// isReviewPassMessage Tests
// ============================================================================

describe("isReviewPassMessage", () => {
  it("returns true for 'review passed'", () => {
    expect(isReviewPassMessage("Review passed")).toBe(true);
    expect(isReviewPassMessage("The review passed successfully")).toBe(true);
  });

  it("returns true for 'review complete'", () => {
    expect(isReviewPassMessage("Review complete")).toBe(true);
  });

  it("returns true for 'review approved'", () => {
    expect(isReviewPassMessage("Review approved")).toBe(true);
  });

  it("returns true for 'no issues found'", () => {
    expect(isReviewPassMessage("No issues found")).toBe(true);
    expect(isReviewPassMessage("No critical issues found in review")).toBe(true);
  });

  it("returns true for 'no findings found'", () => {
    expect(isReviewPassMessage("No findings found in review")).toBe(true);
  });

  it("returns true for 'no problems found'", () => {
    expect(isReviewPassMessage("No problems found")).toBe(true);
  });

  it("returns true for 'LGTM'", () => {
    expect(isReviewPassMessage("LGTM")).toBe(true);
    expect(isReviewPassMessage("LGTM!")).toBe(true);
  });

  it("returns true for 'looks good to me'", () => {
    expect(isReviewPassMessage("Looks good to me")).toBe(true);
    expect(isReviewPassMessage("This looks good to me, ship it!")).toBe(true);
  });

  it("returns true for 'code looks good'", () => {
    expect(isReviewPassMessage("The code looks good")).toBe(true);
  });

  it("returns true for 'approved for merge'", () => {
    expect(isReviewPassMessage("Approved for merge")).toBe(true);
  });

  it("returns true for 'approved to proceed'", () => {
    expect(isReviewPassMessage("Approved to proceed")).toBe(true);
  });

  it("returns false for content with issues", () => {
    expect(isReviewPassMessage("Found 3 issues that need fixing")).toBe(false);
  });

  it("returns false for unrelated content", () => {
    expect(isReviewPassMessage("Implemented new feature")).toBe(false);
  });
});

// ============================================================================
// isReviewAgent Tests
// ============================================================================

describe("isReviewAgent", () => {
  it("returns true for reviewer-agent", () => {
    expect(isReviewAgent("reviewer-agent")).toBe(true);
  });

  it("returns true for spec-check-agent", () => {
    expect(isReviewAgent("spec-check-agent")).toBe(true);
  });

  it("returns true for agents with 'review' in name", () => {
    expect(isReviewAgent("code-review-agent")).toBe(true);
    expect(isReviewAgent("my-custom-review")).toBe(true);
    expect(isReviewAgent("REVIEW-bot")).toBe(true);
  });

  it("returns true for agents with 'reviewer' in name", () => {
    expect(isReviewAgent("skill-reviewer")).toBe(true);
    expect(isReviewAgent("MyReviewer")).toBe(true);
  });

  it("returns false for implementation agents", () => {
    expect(isReviewAgent("code-implementer-agent")).toBe(false);
    expect(isReviewAgent("general")).toBe(false);
    expect(isReviewAgent("frontend-agent")).toBe(false);
  });

  it("returns false for undefined", () => {
    expect(isReviewAgent(undefined)).toBe(false);
  });

  it("returns false for empty string", () => {
    expect(isReviewAgent("")).toBe(false);
  });
});

// ============================================================================
// countWaveCriticalFindings Tests
// ============================================================================

describe("countWaveCriticalFindings", () => {
  it("counts critical findings across all tasks in wave", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({
          id: "T1",
          wave: 1,
          critical_findings: ["Issue 1", "Issue 2"],
        }),
        createTask({
          id: "T2",
          wave: 1,
          critical_findings: ["Issue 3"],
        }),
        createTask({
          id: "T3",
          wave: 1,
          critical_findings: [],
        }),
      ],
    });

    const count = countWaveCriticalFindings(taskGraph, 1);
    expect(count).toBe(3);
  });

  it("only counts findings in specified wave", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({
          id: "T1",
          wave: 1,
          critical_findings: ["Issue 1"],
        }),
        createTask({
          id: "T2",
          wave: 2,
          critical_findings: ["Issue 2", "Issue 3"],
        }),
      ],
    });

    expect(countWaveCriticalFindings(taskGraph, 1)).toBe(1);
    expect(countWaveCriticalFindings(taskGraph, 2)).toBe(2);
  });

  it("returns 0 when no tasks have findings", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1 }),
        createTask({ id: "T2", wave: 1 }),
      ],
    });

    expect(countWaveCriticalFindings(taskGraph, 1)).toBe(0);
  });

  it("returns 0 for wave with no tasks", () => {
    const taskGraph = createTaskGraph({
      tasks: [createTask({ id: "T1", wave: 1 })],
    });

    expect(countWaveCriticalFindings(taskGraph, 2)).toBe(0);
  });

  it("handles undefined critical_findings", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, critical_findings: undefined }),
        createTask({ id: "T2", wave: 1, critical_findings: ["Issue"] }),
      ],
    });

    expect(countWaveCriticalFindings(taskGraph, 1)).toBe(1);
  });
});

// ============================================================================
// getBlockedTasks Tests
// ============================================================================

describe("getBlockedTasks", () => {
  it("returns tasks with critical findings in wave", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, critical_findings: ["Issue 1"] }),
        createTask({ id: "T2", wave: 1, critical_findings: [] }),
        createTask({ id: "T3", wave: 1, critical_findings: ["Issue 2"] }),
      ],
    });

    const blocked = getBlockedTasks(taskGraph, 1);
    expect(blocked).toHaveLength(2);
    expect(blocked.map((t) => t.id)).toEqual(["T1", "T3"]);
  });

  it("only returns tasks from specified wave", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, critical_findings: ["Issue 1"] }),
        createTask({ id: "T2", wave: 2, critical_findings: ["Issue 2"] }),
      ],
    });

    const blockedWave1 = getBlockedTasks(taskGraph, 1);
    expect(blockedWave1).toHaveLength(1);
    expect(blockedWave1[0]?.id).toBe("T1");

    const blockedWave2 = getBlockedTasks(taskGraph, 2);
    expect(blockedWave2).toHaveLength(1);
    expect(blockedWave2[0]?.id).toBe("T2");
  });

  it("returns empty array when no blocked tasks", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, critical_findings: [] }),
        createTask({ id: "T2", wave: 1 }),
      ],
    });

    expect(getBlockedTasks(taskGraph, 1)).toHaveLength(0);
  });

  it("excludes tasks with undefined critical_findings", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, critical_findings: undefined }),
      ],
    });

    expect(getBlockedTasks(taskGraph, 1)).toHaveLength(0);
  });
});

// ============================================================================
// areAllTasksReviewed Tests
// ============================================================================

describe("areAllTasksReviewed", () => {
  it("returns true when all tasks have review_status passed", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, review_status: "passed" }),
        createTask({ id: "T2", wave: 1, review_status: "passed" }),
      ],
    });

    expect(areAllTasksReviewed(taskGraph, 1)).toBe(true);
  });

  it("returns true when all tasks have review_status blocked", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, review_status: "blocked" }),
      ],
    });

    expect(areAllTasksReviewed(taskGraph, 1)).toBe(true);
  });

  it("returns true for mixed passed and blocked", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, review_status: "passed" }),
        createTask({ id: "T2", wave: 1, review_status: "blocked" }),
      ],
    });

    expect(areAllTasksReviewed(taskGraph, 1)).toBe(true);
  });

  it("returns false when any task has pending review", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, review_status: "passed" }),
        createTask({ id: "T2", wave: 1, review_status: "pending" }),
      ],
    });

    expect(areAllTasksReviewed(taskGraph, 1)).toBe(false);
  });

  it("returns false when any task has no review_status", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, review_status: "passed" }),
        createTask({ id: "T2", wave: 1 }),
      ],
    });

    expect(areAllTasksReviewed(taskGraph, 1)).toBe(false);
  });

  it("only checks tasks in specified wave", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, review_status: "passed" }),
        createTask({ id: "T2", wave: 2, review_status: undefined }),
      ],
    });

    expect(areAllTasksReviewed(taskGraph, 1)).toBe(true);
    expect(areAllTasksReviewed(taskGraph, 2)).toBe(false);
  });

  it("returns true for wave with no tasks", () => {
    const taskGraph = createTaskGraph({
      tasks: [createTask({ id: "T1", wave: 1 })],
    });

    expect(areAllTasksReviewed(taskGraph, 2)).toBe(true);
  });
});
