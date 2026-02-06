/**
 * Tests for validate-task-execution hook
 */

import { describe, it, expect } from "vitest";
import {
  validateTaskExecution,
  checkWaveOrder,
  checkDependencies,
  checkReviewGate,
  isTaskReady,
  getReadyTasks,
  getRemainingTasks,
} from "./validate-task-execution";
import type { TaskGraph, Task, TaskToolInput } from "../types";

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

function createTaskInput(taskId: string): TaskToolInput {
  return {
    tool: "Task",
    args: {
      prompt: `Implement **Task ID:** ${taskId} - Create component`,
      description: `${taskId} implementation`,
      subagent_type: "code-implementer-agent",
    },
  };
}

// ============================================================================
// validateTaskExecution Tests
// ============================================================================

describe("validateTaskExecution", () => {
  describe("when no task graph exists", () => {
    it("allows any task execution", () => {
      const result = validateTaskExecution(createTaskInput("T1"), null);
      expect(result.allowed).toBe(true);
    });
  });

  describe("when not a Task tool", () => {
    it("allows non-Task tools", () => {
      const taskGraph = createTaskGraph({
        tasks: [createTask({ id: "T1", wave: 2 })],
      });

      const input = { tool: "Edit", args: { file: "test.ts" } };
      const result = validateTaskExecution(input as TaskToolInput, taskGraph);
      expect(result.allowed).toBe(true);
    });
  });

  describe("when task not in graph", () => {
    it("allows ad-hoc tasks", () => {
      const taskGraph = createTaskGraph({
        tasks: [createTask({ id: "T1" })],
      });

      const result = validateTaskExecution(
        createTaskInput("T99"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
      expect(result.taskId).toBe("T99");
    });
  });

  describe("wave order validation", () => {
    it("allows task in current wave", () => {
      const taskGraph = createTaskGraph({
        current_wave: 2,
        tasks: [createTask({ id: "T1", wave: 2 })],
        // Wave 1 gate must be passed to work on wave 2
        wave_gates: { 1: { reviews_complete: true } },
      });

      const result = validateTaskExecution(
        createTaskInput("T1"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
    });

    it("allows task in earlier wave", () => {
      const taskGraph = createTaskGraph({
        current_wave: 3,
        tasks: [createTask({ id: "T1", wave: 2 })],
        // Need gates passed for waves 1 and 2
        wave_gates: {
          1: { reviews_complete: true },
          2: { reviews_complete: true },
        },
      });

      const result = validateTaskExecution(
        createTaskInput("T1"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
    });

    it("blocks task from future wave", () => {
      const taskGraph = createTaskGraph({
        current_wave: 1,
        tasks: [createTask({ id: "T1", wave: 3 })],
      });

      expect(() =>
        validateTaskExecution(createTaskInput("T1"), taskGraph)
      ).toThrow(/wave 3.*wave 1/i);
    });
  });

  describe("dependency validation", () => {
    it("allows task with no dependencies", () => {
      const taskGraph = createTaskGraph({
        tasks: [createTask({ id: "T1", depends_on: [] })],
      });

      const result = validateTaskExecution(
        createTaskInput("T1"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
    });

    it("allows task with completed dependencies", () => {
      const taskGraph = createTaskGraph({
        tasks: [
          createTask({ id: "T1", status: "completed" }),
          createTask({ id: "T2", depends_on: ["T1"] }),
        ],
      });

      const result = validateTaskExecution(
        createTaskInput("T2"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
    });

    it("allows task with implemented dependencies", () => {
      const taskGraph = createTaskGraph({
        tasks: [
          createTask({ id: "T1", status: "implemented" }),
          createTask({ id: "T2", depends_on: ["T1"] }),
        ],
      });

      const result = validateTaskExecution(
        createTaskInput("T2"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
    });

    it("blocks task with pending dependencies", () => {
      const taskGraph = createTaskGraph({
        tasks: [
          createTask({ id: "T1", status: "pending" }),
          createTask({ id: "T2", depends_on: ["T1"] }),
        ],
      });

      expect(() =>
        validateTaskExecution(createTaskInput("T2"), taskGraph)
      ).toThrow(/dependencies not met/i);
    });

    it("blocks task with in_progress dependencies", () => {
      const taskGraph = createTaskGraph({
        tasks: [
          createTask({ id: "T1", status: "in_progress" }),
          createTask({ id: "T2", depends_on: ["T1"] }),
        ],
      });

      expect(() =>
        validateTaskExecution(createTaskInput("T2"), taskGraph)
      ).toThrow(/dependencies not met/i);
    });
  });

  describe("review gate validation", () => {
    it("allows task in wave 1 without gate check", () => {
      const taskGraph = createTaskGraph({
        current_wave: 1,
        tasks: [createTask({ id: "T1", wave: 1 })],
      });

      const result = validateTaskExecution(
        createTaskInput("T1"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
    });

    it("allows task in wave 2 when wave 1 gate passed", () => {
      const taskGraph = createTaskGraph({
        current_wave: 2,
        tasks: [createTask({ id: "T1", wave: 2 })],
        wave_gates: {
          1: { reviews_complete: true },
        },
      });

      const result = validateTaskExecution(
        createTaskInput("T1"),
        taskGraph
      );
      expect(result.allowed).toBe(true);
    });

    it("blocks task when previous wave gate not passed", () => {
      const taskGraph = createTaskGraph({
        current_wave: 2,
        tasks: [createTask({ id: "T1", wave: 2 })],
        wave_gates: {
          1: { reviews_complete: false },
        },
      });

      expect(() =>
        validateTaskExecution(createTaskInput("T1"), taskGraph)
      ).toThrow(/wave 1 review gate/i);
    });

    it("blocks task when no gate record exists", () => {
      const taskGraph = createTaskGraph({
        current_wave: 2,
        tasks: [createTask({ id: "T1", wave: 2 })],
        wave_gates: {},
      });

      expect(() =>
        validateTaskExecution(createTaskInput("T1"), taskGraph)
      ).toThrow(/wave 1 review gate/i);
    });
  });
});

// ============================================================================
// checkWaveOrder Tests
// ============================================================================

describe("checkWaveOrder", () => {
  it("allows task in current wave", () => {
    const task = createTask({ id: "T1", wave: 2 });
    const result = checkWaveOrder(task, 2);
    expect(result.allowed).toBe(true);
  });

  it("allows task in earlier wave", () => {
    const task = createTask({ id: "T1", wave: 1 });
    const result = checkWaveOrder(task, 3);
    expect(result.allowed).toBe(true);
  });

  it("blocks task from future wave", () => {
    const task = createTask({ id: "T1", wave: 5 });
    const result = checkWaveOrder(task, 2);
    expect(result.allowed).toBe(false);
    expect(result.reason).toContain("wave 5");
  });
});

// ============================================================================
// checkDependencies Tests
// ============================================================================

describe("checkDependencies", () => {
  it("allows task with no dependencies", () => {
    const task = createTask({ id: "T1", depends_on: [] });
    const result = checkDependencies(task, []);
    expect(result.allowed).toBe(true);
  });

  it("allows when all dependencies are completed", () => {
    const task = createTask({ id: "T2", depends_on: ["T1"] });
    const allTasks = [
      createTask({ id: "T1", status: "completed" }),
      task,
    ];

    const result = checkDependencies(task, allTasks);
    expect(result.allowed).toBe(true);
  });

  it("allows when all dependencies are implemented", () => {
    const task = createTask({ id: "T2", depends_on: ["T1"] });
    const allTasks = [
      createTask({ id: "T1", status: "implemented" }),
      task,
    ];

    const result = checkDependencies(task, allTasks);
    expect(result.allowed).toBe(true);
  });

  it("blocks when dependency is pending", () => {
    const task = createTask({ id: "T2", depends_on: ["T1"] });
    const allTasks = [
      createTask({ id: "T1", status: "pending" }),
      task,
    ];

    const result = checkDependencies(task, allTasks);
    expect(result.allowed).toBe(false);
    expect(result.reason).toContain("T1");
  });

  it("blocks when dependency is missing", () => {
    const task = createTask({ id: "T2", depends_on: ["T99"] });
    const allTasks = [task];

    const result = checkDependencies(task, allTasks);
    expect(result.allowed).toBe(false);
    expect(result.reason).toContain("T99");
  });

  it("handles multiple dependencies", () => {
    const task = createTask({ id: "T3", depends_on: ["T1", "T2"] });
    const allTasks = [
      createTask({ id: "T1", status: "completed" }),
      createTask({ id: "T2", status: "pending" }),
      task,
    ];

    const result = checkDependencies(task, allTasks);
    expect(result.allowed).toBe(false);
    expect(result.reason).toContain("T2");
  });
});

// ============================================================================
// checkReviewGate Tests
// ============================================================================

describe("checkReviewGate", () => {
  it("passes when reviews_complete is true", () => {
    const taskGraph = createTaskGraph({
      wave_gates: { 1: { reviews_complete: true } },
    });

    const result = checkReviewGate(1, taskGraph);
    expect(result.allowed).toBe(true);
  });

  it("fails when reviews_complete is false", () => {
    const taskGraph = createTaskGraph({
      wave_gates: { 1: { reviews_complete: false } },
    });

    const result = checkReviewGate(1, taskGraph);
    expect(result.allowed).toBe(false);
  });

  it("fails when gate record is missing", () => {
    const taskGraph = createTaskGraph({ wave_gates: {} });

    const result = checkReviewGate(1, taskGraph);
    expect(result.allowed).toBe(false);
  });

  it("includes blocked reasons when gate is blocked", () => {
    const taskGraph = createTaskGraph({
      wave_gates: {
        1: { reviews_complete: false, blocked: true, tests_passed: false },
      },
      tasks: [
        createTask({
          id: "T1",
          wave: 1,
          critical_findings: ["Finding 1"],
        }),
      ],
    });

    const result = checkReviewGate(1, taskGraph);
    expect(result.allowed).toBe(false);
    expect(result.reason).toContain("tests failed");
    expect(result.reason).toContain("critical");
  });
});

// ============================================================================
// isTaskReady Tests
// ============================================================================

describe("isTaskReady", () => {
  it("returns true when task is ready", () => {
    const task = createTask({ id: "T1", wave: 1 });
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [task],
    });

    expect(isTaskReady(task, taskGraph)).toBe(true);
  });

  it("returns false when wave not ready", () => {
    const task = createTask({ id: "T1", wave: 3 });
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [task],
    });

    expect(isTaskReady(task, taskGraph)).toBe(false);
  });

  it("returns false when dependencies not met", () => {
    const task = createTask({ id: "T2", depends_on: ["T1"] });
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [
        createTask({ id: "T1", status: "pending" }),
        task,
      ],
    });

    expect(isTaskReady(task, taskGraph)).toBe(false);
  });
});

// ============================================================================
// getReadyTasks Tests
// ============================================================================

describe("getReadyTasks", () => {
  it("returns tasks that are ready in current wave", () => {
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [
        createTask({ id: "T1", wave: 1, status: "pending" }),
        createTask({ id: "T2", wave: 1, status: "pending" }),
        createTask({ id: "T3", wave: 2, status: "pending" }),
      ],
    });

    const ready = getReadyTasks(taskGraph);
    expect(ready.map((t) => t.id)).toEqual(["T1", "T2"]);
  });

  it("excludes completed tasks", () => {
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [
        createTask({ id: "T1", wave: 1, status: "completed" }),
        createTask({ id: "T2", wave: 1, status: "pending" }),
      ],
    });

    const ready = getReadyTasks(taskGraph);
    expect(ready.map((t) => t.id)).toEqual(["T2"]);
  });

  it("excludes in_progress tasks", () => {
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [
        createTask({ id: "T1", wave: 1, status: "in_progress" }),
        createTask({ id: "T2", wave: 1, status: "pending" }),
      ],
    });

    const ready = getReadyTasks(taskGraph);
    expect(ready.map((t) => t.id)).toEqual(["T2"]);
  });
});

// ============================================================================
// getRemainingTasks Tests
// ============================================================================

describe("getRemainingTasks", () => {
  it("returns tasks not yet completed", () => {
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [
        createTask({ id: "T1", wave: 1, status: "completed" }),
        createTask({ id: "T2", wave: 1, status: "pending" }),
        createTask({ id: "T3", wave: 1, status: "in_progress" }),
      ],
    });

    const remaining = getRemainingTasks(taskGraph);
    expect(remaining.map((t) => t.id)).toEqual(["T2", "T3"]);
  });

  it("excludes implemented tasks", () => {
    const taskGraph = createTaskGraph({
      current_wave: 1,
      tasks: [
        createTask({ id: "T1", wave: 1, status: "implemented" }),
        createTask({ id: "T2", wave: 1, status: "pending" }),
      ],
    });

    const remaining = getRemainingTasks(taskGraph);
    expect(remaining.map((t) => t.id)).toEqual(["T2"]);
  });
});
