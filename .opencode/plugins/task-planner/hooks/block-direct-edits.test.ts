/**
 * Unit tests for block-direct-edits.ts
 *
 * Tests the hook that blocks direct Edit/Write tools during orchestration.
 */

import { describe, it, expect } from "vitest";
import {
  blockDirectEdits,
  isOrchestrationActive,
  getBlockedTools,
} from "./block-direct-edits";
import type { TaskGraph, ToolExecuteInput } from "../types";

// ============================================================================
// Test Fixtures
// ============================================================================

function createTaskGraph(overrides: Partial<TaskGraph> = {}): TaskGraph {
  return {
    title: "Test Task Graph",
    spec_file: ".opencode/specs/test/spec.md",
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

function createToolInput(tool: string, args: Record<string, unknown> = {}): ToolExecuteInput {
  return {
    tool,
    args,
  };
}

// ============================================================================
// blockDirectEdits Tests
// ============================================================================

describe("blockDirectEdits", () => {
  describe("when no task graph exists", () => {
    it("allows Edit tool", () => {
      const input = createToolInput("Edit", { filePath: "/test/file.ts" });
      
      expect(() => {
        blockDirectEdits(input, null);
      }).not.toThrow();
    });

    it("allows Write tool", () => {
      const input = createToolInput("Write", { filePath: "/test/file.ts" });
      
      expect(() => {
        blockDirectEdits(input, null);
      }).not.toThrow();
    });
  });

  describe("when task graph exists (orchestration active)", () => {
    it("blocks Edit tool", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Edit", { filePath: "/test/file.ts" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).toThrow(/blocked/i);
    });

    it("blocks Write tool", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Write", { filePath: "/test/file.ts" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).toThrow(/blocked/i);
    });

    it("blocks edit tool (lowercase)", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("edit", { filePath: "/test/file.ts" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).toThrow(/blocked/i);
    });

    it("blocks write tool (lowercase)", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("write", { filePath: "/test/file.ts" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).toThrow(/blocked/i);
    });

    it("allows Read tool", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Read", { filePath: "/test/file.ts" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).not.toThrow();
    });

    it("allows Bash tool", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Bash", { command: "ls -la" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).not.toThrow();
    });

    it("allows Task tool", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Task", { prompt: "Do something" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).not.toThrow();
    });

    it("allows Glob tool", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Glob", { pattern: "**/*.ts" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).not.toThrow();
    });

    it("allows Grep tool", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Grep", { pattern: "function" });
      
      expect(() => {
        blockDirectEdits(input, taskGraph);
      }).not.toThrow();
    });
  });

  describe("error message", () => {
    it("provides guidance on using agents", () => {
      const taskGraph = createTaskGraph();
      const input = createToolInput("Edit", { filePath: "/test/file.ts" });
      
      try {
        blockDirectEdits(input, taskGraph);
        expect.fail("Should have thrown");
      } catch (error) {
        const message = (error as Error).message;
        expect(message).toContain("agent");
        expect(message).toContain("code-implementer-agent");
      }
    });
  });
});

// ============================================================================
// isOrchestrationActive Tests
// ============================================================================

describe("isOrchestrationActive", () => {
  it("returns false when taskGraph is null", () => {
    expect(isOrchestrationActive(null)).toBe(false);
  });

  it("returns true when taskGraph exists", () => {
    const taskGraph = createTaskGraph();
    expect(isOrchestrationActive(taskGraph)).toBe(true);
  });
});

// ============================================================================
// getBlockedTools Tests
// ============================================================================

describe("getBlockedTools", () => {
  it("returns an array of blocked tools", () => {
    const blocked = getBlockedTools();
    
    expect(Array.isArray(blocked)).toBe(true);
    expect(blocked.length).toBeGreaterThan(0);
  });

  it("includes Edit and Write tools", () => {
    const blocked = getBlockedTools();
    const lowerBlocked = blocked.map((t) => t.toLowerCase());
    
    expect(lowerBlocked).toContain("edit");
    expect(lowerBlocked).toContain("write");
  });
});
