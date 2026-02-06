/**
 * Unit tests for task-id-extractor.ts
 *
 * Tests the flexible task ID extraction from prompts and descriptions.
 */

import { describe, it, expect } from "vitest";
import {
  extractTaskId,
  extractTaskIdFromArgs,
  isCanonicalFormat,
  getCanonicalFormat,
  validateTaskIdFormat,
  extractAllTaskIds,
} from "./task-id-extractor";

// ============================================================================
// extractTaskId Tests
// ============================================================================

describe("extractTaskId", () => {
  describe("canonical format", () => {
    it("extracts from **Task ID:** T1", () => {
      expect(extractTaskId("**Task ID:** T1")).toBe("T1");
    });

    it("extracts from **Task ID:** T12", () => {
      expect(extractTaskId("**Task ID:** T12")).toBe("T12");
    });

    it("extracts from **Task ID:**T1 (no space)", () => {
      expect(extractTaskId("**Task ID:**T1")).toBe("T1");
    });
  });

  describe("REVIEW_TASK format", () => {
    it("extracts from REVIEW_TASK: T1", () => {
      expect(extractTaskId("REVIEW_TASK: T1")).toBe("T1");
    });

    it("extracts from **REVIEW_TASK:** T2", () => {
      expect(extractTaskId("**REVIEW_TASK:** T2")).toBe("T2");
    });
  });

  describe("plain Task ID format", () => {
    it("extracts from Task ID: T1", () => {
      expect(extractTaskId("Task ID: T1")).toBe("T1");
    });

    it("extracts from task id: t3 (case insensitive)", () => {
      expect(extractTaskId("task id: t3")).toBe("T3");
    });
  });

  describe("Task: format", () => {
    it("extracts from Task: T1", () => {
      expect(extractTaskId("Task: T1")).toBe("T1");
    });

    it("extracts from task t5 (no colon)", () => {
      expect(extractTaskId("task t5")).toBe("T5");
    });
  });

  describe("description start format", () => {
    it("extracts from T1 - Description", () => {
      expect(extractTaskId("T1 - Description")).toBe("T1");
    });

    it("extracts from T2: Description", () => {
      expect(extractTaskId("T2: Description")).toBe("T2");
    });

    it("extracts from T3 Description", () => {
      expect(extractTaskId("T3 Description")).toBe("T3");
    });
  });

  describe("verb + task format", () => {
    it("extracts from implement T1", () => {
      expect(extractTaskId("implement T1")).toBe("T1");
    });

    it("extracts from fix T2", () => {
      expect(extractTaskId("fix T2")).toBe("T2");
    });

    it("extracts from complete T3", () => {
      expect(extractTaskId("complete T3")).toBe("T3");
    });

    it("extracts from execute T4", () => {
      expect(extractTaskId("execute T4")).toBe("T4");
    });

    it("extracts from working on T5", () => {
      expect(extractTaskId("working on T5")).toBe("T5");
    });
  });

  describe("task description format", () => {
    it("extracts from T3 Create new component", () => {
      expect(extractTaskId("T3 Create new component")).toBe("T3");
    });
  });

  describe("standalone format", () => {
    it("extracts bare T1", () => {
      expect(extractTaskId("T1")).toBe("T1");
    });

    it("extracts T1 from middle of text", () => {
      expect(extractTaskId("We need to work on T1 today")).toBe("T1");
    });

    it("handles lowercase t1 in context", () => {
      // Bare lowercase t1 doesn't match (word boundary issue with single char)
      // but in context it should work
      expect(extractTaskId("work on t1")).toBe("T1");
    });
  });

  describe("edge cases", () => {
    it("returns null for empty string", () => {
      expect(extractTaskId("")).toBeNull();
    });

    it("returns null for text without task ID", () => {
      expect(extractTaskId("No task here")).toBeNull();
    });

    it("returns first match when multiple IDs present", () => {
      const result = extractTaskId("**Task ID:** T1 then T2 and T3");
      expect(result).toBe("T1");
    });

    it("handles task ID in longer context", () => {
      const prompt = `
        Please implement the following task:
        
        **Task ID:** T5
        
        Description: Add validation to form
      `;
      expect(extractTaskId(prompt)).toBe("T5");
    });
  });
});

// ============================================================================
// extractTaskIdFromArgs Tests
// ============================================================================

describe("extractTaskIdFromArgs", () => {
  it("extracts from prompt", () => {
    const result = extractTaskIdFromArgs({
      prompt: "Implement **Task ID:** T1",
    });
    expect(result).toBe("T1");
  });

  it("extracts from description when prompt has no ID", () => {
    const result = extractTaskIdFromArgs({
      prompt: "Do some work",
      description: "T2 Create component",
    });
    expect(result).toBe("T2");
  });

  it("prefers prompt over description", () => {
    const result = extractTaskIdFromArgs({
      prompt: "Work on T1",
      description: "T2 fallback",
    });
    expect(result).toBe("T1");
  });

  it("returns null when no ID in either field", () => {
    const result = extractTaskIdFromArgs({
      prompt: "Do something",
      description: "Some description",
    });
    expect(result).toBeNull();
  });

  it("handles missing prompt", () => {
    const result = extractTaskIdFromArgs({
      description: "T3 task",
    });
    expect(result).toBe("T3");
  });

  it("handles missing description", () => {
    const result = extractTaskIdFromArgs({
      prompt: "T4 work",
    });
    expect(result).toBe("T4");
  });

  it("returns null for empty args", () => {
    const result = extractTaskIdFromArgs({});
    expect(result).toBeNull();
  });
});

// ============================================================================
// isCanonicalFormat Tests
// ============================================================================

describe("isCanonicalFormat", () => {
  it("returns true for **Task ID:** T1", () => {
    expect(isCanonicalFormat("**Task ID:** T1")).toBe(true);
  });

  it("returns false for Task ID: T1", () => {
    expect(isCanonicalFormat("Task ID: T1")).toBe(false);
  });

  it("returns false for bare T1", () => {
    expect(isCanonicalFormat("T1")).toBe(false);
  });
});

// ============================================================================
// getCanonicalFormat Tests
// ============================================================================

describe("getCanonicalFormat", () => {
  it("formats T1 to **Task ID:** T1", () => {
    expect(getCanonicalFormat("T1")).toBe("**Task ID:** T1");
  });

  it("uppercases lowercase task IDs", () => {
    expect(getCanonicalFormat("t5")).toBe("**Task ID:** T5");
  });
});

// ============================================================================
// validateTaskIdFormat Tests
// ============================================================================

describe("validateTaskIdFormat", () => {
  it("returns 'canonical' for **Task ID:** T1", () => {
    expect(validateTaskIdFormat("**Task ID:** T1")).toBe("canonical");
  });

  it("returns 'valid' for Task ID: T1", () => {
    expect(validateTaskIdFormat("Task ID: T1")).toBe("valid");
  });

  it("returns 'valid' for bare T1", () => {
    expect(validateTaskIdFormat("T1")).toBe("valid");
  });

  it("returns 'none' for no task ID", () => {
    expect(validateTaskIdFormat("No ID here")).toBe("none");
  });
});

// ============================================================================
// extractAllTaskIds Tests
// ============================================================================

describe("extractAllTaskIds", () => {
  it("extracts single task ID", () => {
    expect(extractAllTaskIds("T1")).toEqual(["T1"]);
  });

  it("extracts multiple task IDs", () => {
    expect(extractAllTaskIds("T1, T2, T3")).toEqual(["T1", "T2", "T3"]);
  });

  it("deduplicates repeated IDs", () => {
    expect(extractAllTaskIds("T1 then T1 again")).toEqual(["T1"]);
  });

  it("preserves order of first appearance", () => {
    expect(extractAllTaskIds("T3, T1, T2")).toEqual(["T3", "T1", "T2"]);
  });

  it("uppercases all IDs", () => {
    expect(extractAllTaskIds("t1, t2")).toEqual(["T1", "T2"]);
  });

  it("returns empty array for no IDs", () => {
    expect(extractAllTaskIds("No tasks")).toEqual([]);
  });

  it("returns empty array for empty string", () => {
    expect(extractAllTaskIds("")).toEqual([]);
  });

  it("handles complex text", () => {
    const text = `
      Dependencies: T1, T2
      This task (T3) depends on T1 and T2
    `;
    expect(extractAllTaskIds(text)).toEqual(["T1", "T2", "T3"]);
  });
});
