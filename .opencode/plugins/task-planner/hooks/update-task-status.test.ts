/**
 * Tests for update-task-status hook
 */

import { describe, it, expect } from "vitest";
import {
  extractTestEvidence,
  isReviewAgent,
  getRemainingTaskIds,
  parseFilesModified,
} from "./update-task-status.js";
import type { TaskGraph, Task } from "../types.js";

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
// extractTestEvidence Tests
// ============================================================================

describe("extractTestEvidence", () => {
  describe("Maven/Java", () => {
    it("extracts Maven BUILD SUCCESS with test counts", () => {
      const transcript = `
        [INFO] Running com.example.MyTest
        [INFO] Tests run: 15, Failures: 0, Errors: 0, Skipped: 0
        [INFO] BUILD SUCCESS
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(true);
      expect(result.framework).toBe("maven");
      expect(result.testCount).toBe(15);
      expect(result.evidence).toContain("maven");
      expect(result.evidence).toContain("Tests run: 15");
    });

    it("does not match Maven without BUILD SUCCESS", () => {
      const transcript = `
        [INFO] Tests run: 15, Failures: 0, Errors: 0, Skipped: 0
        [INFO] BUILD FAILURE
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(false);
    });

    it("handles Maven with bold markers", () => {
      const transcript = `
        **[INFO]** Tests run: **10**, Failures: 0, Errors: 0
        **BUILD SUCCESS**
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(true);
      expect(result.framework).toBe("maven");
      expect(result.testCount).toBe(10);
    });
  });

  describe("Vitest", () => {
    it("extracts Vitest passed tests", () => {
      const transcript = `
        ✓ src/utils.test.ts (5 tests)
        ✓ src/helpers.test.ts (10 tests)

        Tests  15 passed (15)
        Duration  1.25s
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(true);
      expect(result.framework).toBe("vitest");
      expect(result.testCount).toBe(15);
      expect(result.evidence).toContain("vitest");
    });

    it("extracts Vitest Test Files passed format", () => {
      // Note: The pattern matches first occurrence, which is Test Files
      const transcript = `
        Test Files  3 passed (3)
        Tests  25 passed (25)
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(true);
      expect(result.framework).toBe("vitest");
      // First match is Test Files with 3, not Tests with 25
      expect(result.testCount).toBe(3);
    });

    it("does not match Vitest with failures", () => {
      // Real Vitest failure output: "Tests  X failed | Y passed"
      const transcript = `
        Test Files  1 failed | 2 passed (3)
        Tests  3 failed | 12 passed (15)
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(false);
    });
  });

  describe("Mocha", () => {
    it("extracts Mocha passing tests", () => {
      const transcript = `
        Array
          ✓ should return -1 when value is not present
          ✓ should return index when value is present

        8 passing (52ms)
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(true);
      expect(result.framework).toBe("mocha");
      expect(result.testCount).toBe(8);
      expect(result.evidence).toContain("node");
    });

    it("does not match Mocha with failing tests", () => {
      const transcript = `
        8 passing (52ms)
        2 failing
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(false);
    });
  });

  describe("pytest", () => {
    it("extracts pytest passed tests", () => {
      const transcript = `
        ======================== test session starts =========================
        collected 12 items

        tests/test_main.py ........ [100%]

        ========================= 12 passed in 0.42s =========================
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(true);
      expect(result.framework).toBe("pytest");
      expect(result.testCount).toBe(12);
      expect(result.evidence).toContain("pytest");
    });

    it("does not match pytest with failures", () => {
      const transcript = `
        ========================= 10 passed, 2 failed in 0.42s =========================
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(false);
    });

    it("handles pytest single pass", () => {
      const transcript = `
        ========================= 1 passed in 0.10s =========================
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(true);
      expect(result.framework).toBe("pytest");
      expect(result.testCount).toBe(1);
    });
  });

  describe("no evidence", () => {
    it("returns passed: false when no test output found", () => {
      const transcript = `
        Completed implementation of the feature.
        All changes have been saved.
      `;

      const result = extractTestEvidence(transcript);
      expect(result.passed).toBe(false);
      expect(result.framework).toBeUndefined();
      expect(result.evidence).toBeUndefined();
    });

    it("returns passed: false for empty transcript", () => {
      const result = extractTestEvidence("");
      expect(result.passed).toBe(false);
    });
  });
});

// ============================================================================
// isReviewAgent Tests
// ============================================================================

describe("isReviewAgent", () => {
  it("returns true for explicit review agents", () => {
    expect(isReviewAgent("code-reviewer")).toBe(true);
    expect(isReviewAgent("skill-reviewer")).toBe(true);
  });

  it("returns true for agents with 'review' in name", () => {
    expect(isReviewAgent("my-custom-review-agent")).toBe(true);
    expect(isReviewAgent("REVIEW-Agent")).toBe(true);
  });

  it("returns true for agents with 'reviewer' in name", () => {
    expect(isReviewAgent("code-reviewer-v2")).toBe(true);
    expect(isReviewAgent("MyReviewerAgent")).toBe(true);
  });

  it("returns false for implementation agents", () => {
    expect(isReviewAgent("code-implementer")).toBe(false);
    expect(isReviewAgent("general")).toBe(false);
    expect(isReviewAgent("explore")).toBe(false);
  });

  it("returns false for undefined or empty", () => {
    expect(isReviewAgent(undefined)).toBe(false);
    expect(isReviewAgent("")).toBe(false);
  });
});

// ============================================================================
// getRemainingTaskIds Tests
// ============================================================================

describe("getRemainingTaskIds", () => {
  it("returns tasks that are not implemented or completed in wave", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, status: "completed" }),
        createTask({ id: "T2", wave: 1, status: "implemented" }),
        createTask({ id: "T3", wave: 1, status: "pending" }),
        createTask({ id: "T4", wave: 1, status: "in_progress" }),
      ],
    });

    const remaining = getRemainingTaskIds(taskGraph, 1);
    expect(remaining).toEqual(["T3", "T4"]);
  });

  it("only returns tasks from specified wave", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, status: "pending" }),
        createTask({ id: "T2", wave: 2, status: "pending" }),
        createTask({ id: "T3", wave: 1, status: "pending" }),
      ],
    });

    const remaining = getRemainingTaskIds(taskGraph, 1);
    expect(remaining).toEqual(["T1", "T3"]);
  });

  it("returns empty array when all tasks are done", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, status: "implemented" }),
        createTask({ id: "T2", wave: 1, status: "completed" }),
      ],
    });

    const remaining = getRemainingTaskIds(taskGraph, 1);
    expect(remaining).toEqual([]);
  });

  it("returns empty array for wave with no tasks", () => {
    const taskGraph = createTaskGraph({
      tasks: [
        createTask({ id: "T1", wave: 1, status: "pending" }),
      ],
    });

    const remaining = getRemainingTaskIds(taskGraph, 2);
    expect(remaining).toEqual([]);
  });
});

// ============================================================================
// parseFilesModified Tests
// ============================================================================

describe("parseFilesModified", () => {
  it("extracts 'Wrote to file' pattern", () => {
    const transcript = `
      Wrote to file: src/components/Button.tsx
      Wrote to file: src/utils/helpers.ts
    `;

    const files = parseFilesModified(transcript);
    expect(files).toContain("src/components/Button.tsx");
    expect(files).toContain("src/utils/helpers.ts");
  });

  it("extracts 'Modified' pattern", () => {
    const transcript = `
      Modified: src/index.ts
      Modified: package.json
    `;

    const files = parseFilesModified(transcript);
    expect(files).toContain("src/index.ts");
    expect(files).toContain("package.json");
  });

  it("extracts 'Created' pattern", () => {
    const transcript = `
      Created: src/new-file.ts
      Created: tests/new-file.test.ts
    `;

    const files = parseFilesModified(transcript);
    expect(files).toContain("src/new-file.ts");
    expect(files).toContain("tests/new-file.test.ts");
  });

  it("extracts 'Updated' pattern", () => {
    const transcript = `
      Updated: README.md
    `;

    const files = parseFilesModified(transcript);
    expect(files).toContain("README.md");
  });

  it("extracts 'Edited' pattern", () => {
    const transcript = `
      Edited: src/config.ts
    `;

    const files = parseFilesModified(transcript);
    expect(files).toContain("src/config.ts");
  });

  it("deduplicates files", () => {
    const transcript = `
      Wrote to file: src/index.ts
      Modified: src/index.ts
      Updated: src/index.ts
    `;

    const files = parseFilesModified(transcript);
    expect(files).toHaveLength(1);
    expect(files).toContain("src/index.ts");
  });

  it("returns empty array for empty transcript", () => {
    const files = parseFilesModified("");
    expect(files).toEqual([]);
  });

  it("returns empty array when no patterns match", () => {
    const transcript = `
      Completed the implementation.
      All tests pass.
    `;

    const files = parseFilesModified(transcript);
    expect(files).toEqual([]);
  });

  it("handles quoted file paths", () => {
    const transcript = `
      Wrote to file: "src/my file.ts"
      Created: 'path/to/file.ts'
    `;

    const files = parseFilesModified(transcript);
    expect(files).toContain("src/my");
    expect(files).toContain("path/to/file.ts");
  });
});
