/**
 * Unit tests for state-manager.ts
 *
 * Tests the StateManager class and related utilities.
 * Uses temporary directories for isolated file system operations.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdir, rm, writeFile, readFile } from "fs/promises";
import { existsSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { randomUUID } from "crypto";
import {
  StateManager,
  createStateManager,
  resolveTaskGraphPath,
  registerSessionTaskGraph,
  unregisterSessionTaskGraph,
} from "./state-manager";
import type { TaskGraph, Task } from "../types";

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

function createTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    description: `Task ${id}`,
    wave: 1,
    status: "pending",
    agent: "code-implementer-agent",
    depends_on: [],
    ...overrides,
  };
}

// ============================================================================
// Test Setup
// ============================================================================

let testDir: string;
let stateManager: StateManager;

beforeEach(async () => {
  // Create unique temp directory for each test
  testDir = join(tmpdir(), `task-planner-test-${randomUUID()}`);
  await mkdir(testDir, { recursive: true });
  stateManager = new StateManager(testDir);
});

afterEach(async () => {
  // Clean up temp directory
  if (existsSync(testDir)) {
    await rm(testDir, { recursive: true, force: true });
  }
});

// ============================================================================
// StateManager Core Operations Tests
// ============================================================================

describe("StateManager", () => {
  describe("load/save", () => {
    it("returns null when no state file exists", async () => {
      const result = await stateManager.load();
      expect(result).toBeNull();
    });

    it("saves and loads task graph", async () => {
      const graph = createTaskGraph({ title: "Test Save" });
      
      await stateManager.save(graph);
      const loaded = await stateManager.load();
      
      expect(loaded).not.toBeNull();
      expect(loaded?.title).toBe("Test Save");
    });

    it("creates state directory if needed", async () => {
      const graph = createTaskGraph();
      
      await stateManager.save(graph);
      
      const stateDir = join(testDir, ".opencode/state");
      expect(existsSync(stateDir)).toBe(true);
    });

    it("updates updated_at on save", async () => {
      const graph = createTaskGraph();
      const originalDate = graph.updated_at;
      
      // Wait a bit to ensure time difference
      await new Promise((r) => setTimeout(r, 10));
      await stateManager.save(graph);
      
      const loaded = await stateManager.load();
      expect(loaded?.updated_at).not.toBe(originalDate);
    });
  });

  describe("hasActiveTaskGraph", () => {
    it("returns false when no state exists", async () => {
      expect(await stateManager.hasActiveTaskGraph()).toBe(false);
    });

    it("returns true when state exists", async () => {
      await stateManager.save(createTaskGraph());
      expect(await stateManager.hasActiveTaskGraph()).toBe(true);
    });
  });

  describe("clear", () => {
    it("removes state file", async () => {
      await stateManager.save(createTaskGraph());
      expect(await stateManager.hasActiveTaskGraph()).toBe(true);
      
      await stateManager.clear();
      
      expect(await stateManager.hasActiveTaskGraph()).toBe(false);
    });

    it("handles missing file gracefully", async () => {
      await expect(stateManager.clear()).resolves.not.toThrow();
    });
  });
});

// ============================================================================
// Task Operations Tests
// ============================================================================

describe("StateManager task operations", () => {
  beforeEach(async () => {
    const graph = createTaskGraph({
      tasks: [
        createTask("T1", { wave: 1, status: "pending" }),
        createTask("T2", { wave: 1, status: "in_progress" }),
        createTask("T3", { wave: 2, status: "pending" }),
      ],
    });
    await stateManager.save(graph);
  });

  describe("getTask", () => {
    it("returns task by ID", async () => {
      const task = await stateManager.getTask("T1");
      expect(task).not.toBeNull();
      expect(task?.id).toBe("T1");
    });

    it("returns null for unknown ID", async () => {
      const task = await stateManager.getTask("T99");
      expect(task).toBeNull();
    });
  });

  describe("updateTask", () => {
    it("updates task properties", async () => {
      await stateManager.updateTask("T1", { status: "implemented" });
      
      const task = await stateManager.getTask("T1");
      expect(task?.status).toBe("implemented");
    });

    it("preserves other properties", async () => {
      await stateManager.updateTask("T1", { status: "implemented" });
      
      const task = await stateManager.getTask("T1");
      expect(task?.wave).toBe(1);
      expect(task?.description).toBe("Task T1");
    });
  });

  describe("setTaskStatus", () => {
    it("sets task status", async () => {
      await stateManager.setTaskStatus("T1", "completed");
      
      const task = await stateManager.getTask("T1");
      expect(task?.status).toBe("completed");
    });
  });

  describe("getWaveTasks", () => {
    it("returns tasks for wave", async () => {
      const wave1Tasks = await stateManager.getWaveTasks(1);
      expect(wave1Tasks.length).toBe(2);
      expect(wave1Tasks.every((t) => t.wave === 1)).toBe(true);
    });

    it("returns empty array for empty wave", async () => {
      const wave3Tasks = await stateManager.getWaveTasks(3);
      expect(wave3Tasks).toEqual([]);
    });
  });

  describe("checkDependencies", () => {
    it("returns satisfied for task with no deps", async () => {
      const result = await stateManager.checkDependencies("T1");
      expect(result.satisfied).toBe(true);
      expect(result.unmetDeps).toEqual([]);
    });

    it("returns unmet deps for incomplete dependencies", async () => {
      // Add task with dependency
      const graph = await stateManager.load();
      graph!.tasks.push(createTask("T4", { depends_on: ["T1", "T2"] }));
      await stateManager.save(graph!);
      
      const result = await stateManager.checkDependencies("T4");
      expect(result.satisfied).toBe(false);
      expect(result.unmetDeps).toContain("T1");
      expect(result.unmetDeps).toContain("T2");
    });

    it("considers implemented as complete", async () => {
      await stateManager.updateTask("T1", { status: "implemented" });
      
      const graph = await stateManager.load();
      graph!.tasks.push(createTask("T4", { depends_on: ["T1"] }));
      await stateManager.save(graph!);
      
      const result = await stateManager.checkDependencies("T4");
      expect(result.satisfied).toBe(true);
    });
  });
});

// ============================================================================
// Phase Operations Tests
// ============================================================================

describe("StateManager phase operations", () => {
  beforeEach(async () => {
    await stateManager.save(createTaskGraph({ current_phase: "specify" }));
  });

  describe("getCurrentPhase", () => {
    it("returns current phase", async () => {
      const phase = await stateManager.getCurrentPhase();
      expect(phase).toBe("specify");
    });

    it("returns null when no graph", async () => {
      await stateManager.clear();
      const phase = await stateManager.getCurrentPhase();
      expect(phase).toBeNull();
    });
  });

  describe("setCurrentPhase", () => {
    it("updates current phase", async () => {
      await stateManager.setCurrentPhase("architecture");
      
      const phase = await stateManager.getCurrentPhase();
      expect(phase).toBe("architecture");
    });
  });

  describe("setPhaseArtifact", () => {
    it("records phase artifact", async () => {
      await stateManager.setPhaseArtifact("specify", ".opencode/specs/test.md");
      
      const artifact = await stateManager.getPhaseArtifact("specify");
      expect(artifact).toBe(".opencode/specs/test.md");
    });
  });

  describe("advancePhase", () => {
    it("updates phase and records artifact atomically", async () => {
      await stateManager.advancePhase("specify", "clarify", ".opencode/specs/test.md");
      
      const phase = await stateManager.getCurrentPhase();
      const artifact = await stateManager.getPhaseArtifact("specify");
      
      expect(phase).toBe("clarify");
      expect(artifact).toBe(".opencode/specs/test.md");
    });
  });

  describe("addSkippedPhase", () => {
    it("adds phase to skipped list", async () => {
      await stateManager.addSkippedPhase("clarify");
      
      const skipped = await stateManager.getSkippedPhases();
      expect(skipped).toContain("clarify");
    });

    it("does not duplicate skipped phases", async () => {
      await stateManager.addSkippedPhase("clarify");
      await stateManager.addSkippedPhase("clarify");
      
      const skipped = await stateManager.getSkippedPhases();
      expect(skipped.filter((p) => p === "clarify").length).toBe(1);
    });
  });

  describe("checkArtifactExists", () => {
    it("returns true for 'completed'", async () => {
      const exists = await stateManager.checkArtifactExists("completed", testDir);
      expect(exists).toBe(true);
    });

    it("returns true for empty string", async () => {
      const exists = await stateManager.checkArtifactExists("", testDir);
      expect(exists).toBe(true);
    });

    it("returns true for existing file", async () => {
      const filePath = ".opencode/test.md";
      await mkdir(join(testDir, ".opencode"), { recursive: true });
      await writeFile(join(testDir, filePath), "content");
      
      const exists = await stateManager.checkArtifactExists(filePath, testDir);
      expect(exists).toBe(true);
    });

    it("returns false for missing file", async () => {
      const exists = await stateManager.checkArtifactExists("missing.md", testDir);
      expect(exists).toBe(false);
    });
  });
});

// ============================================================================
// Wave Operations Tests
// ============================================================================

describe("StateManager wave operations", () => {
  beforeEach(async () => {
    await stateManager.save(createTaskGraph({
      current_wave: 1,
      tasks: [
        createTask("T1", { wave: 1, status: "pending" }),
        createTask("T2", { wave: 1, status: "pending" }),
      ],
    }));
  });

  describe("getCurrentWave", () => {
    it("returns current wave", async () => {
      const wave = await stateManager.getCurrentWave();
      expect(wave).toBe(1);
    });
  });

  describe("advanceWave", () => {
    it("increments wave number", async () => {
      const newWave = await stateManager.advanceWave();
      expect(newWave).toBe(2);
      
      const current = await stateManager.getCurrentWave();
      expect(current).toBe(2);
    });
  });

  describe("updateWaveGate", () => {
    it("updates wave gate status", async () => {
      await stateManager.updateWaveGate(1, {
        impl_complete: true,
        tests_passed: true,
      });
      
      const graph = await stateManager.load();
      expect(graph?.wave_gates[1]?.impl_complete).toBe(true);
      expect(graph?.wave_gates[1]?.tests_passed).toBe(true);
    });

    it("sets checked_at timestamp", async () => {
      await stateManager.updateWaveGate(1, { impl_complete: true });
      
      const graph = await stateManager.load();
      expect(graph?.wave_gates[1]?.checked_at).toBeDefined();
    });
  });

  describe("isWaveComplete", () => {
    it("returns false when tasks pending", async () => {
      const complete = await stateManager.isWaveComplete(1);
      expect(complete).toBe(false);
    });

    it("returns true when all tasks implemented", async () => {
      await stateManager.updateTask("T1", { status: "implemented" });
      await stateManager.updateTask("T2", { status: "implemented" });
      
      const complete = await stateManager.isWaveComplete(1);
      expect(complete).toBe(true);
    });

    it("returns true when all tasks completed", async () => {
      await stateManager.updateTask("T1", { status: "completed" });
      await stateManager.updateTask("T2", { status: "completed" });
      
      const complete = await stateManager.isWaveComplete(1);
      expect(complete).toBe(true);
    });
  });
});

// ============================================================================
// Executing Tasks Tests
// ============================================================================

describe("StateManager executing tasks", () => {
  beforeEach(async () => {
    await stateManager.save(createTaskGraph());
  });

  describe("markTaskExecuting", () => {
    it("adds task to executing list", async () => {
      await stateManager.markTaskExecuting("T1");
      
      const graph = await stateManager.load();
      expect(graph?.executing_tasks).toContain("T1");
    });

    it("does not duplicate tasks", async () => {
      await stateManager.markTaskExecuting("T1");
      await stateManager.markTaskExecuting("T1");
      
      const graph = await stateManager.load();
      expect(graph?.executing_tasks.filter((id) => id === "T1").length).toBe(1);
    });
  });

  describe("unmarkTaskExecuting", () => {
    it("removes task from executing list", async () => {
      await stateManager.markTaskExecuting("T1");
      await stateManager.unmarkTaskExecuting("T1");
      
      const graph = await stateManager.load();
      expect(graph?.executing_tasks).not.toContain("T1");
    });

    it("handles task not in list", async () => {
      await expect(stateManager.unmarkTaskExecuting("T99")).resolves.not.toThrow();
    });
  });
});

// ============================================================================
// In-Memory Tracking Tests
// ============================================================================

describe("StateManager in-memory tracking", () => {
  describe("file tracking", () => {
    it("tracks file edits", () => {
      stateManager.trackFileEdit("/path/to/file.ts");
      
      const files = stateManager.getFilesModified();
      expect(files).toContain("/path/to/file.ts");
    });

    it("clears file tracking", () => {
      stateManager.trackFileEdit("/path/to/file.ts");
      stateManager.clearFilesModified();
      
      const files = stateManager.getFilesModified();
      expect(files).toEqual([]);
    });

    it("deduplicates files", () => {
      stateManager.trackFileEdit("/path/to/file.ts");
      stateManager.trackFileEdit("/path/to/file.ts");
      
      const files = stateManager.getFilesModified();
      expect(files.length).toBe(1);
    });
  });

  describe("agent tracking", () => {
    it("registers and retrieves agent", () => {
      const context = {
        agentId: "agent-1",
        agentType: "code-implementer-agent",
        taskId: "T1",
        startedAt: new Date().toISOString(),
      };
      
      stateManager.registerAgent(context);
      
      const retrieved = stateManager.getAgentContext("agent-1");
      expect(retrieved).toEqual(context);
    });

    it("unregisters agent", () => {
      const context = {
        agentId: "agent-1",
        agentType: "code-implementer-agent",
        startedAt: new Date().toISOString(),
      };
      
      stateManager.registerAgent(context);
      stateManager.unregisterAgent("agent-1");
      
      expect(stateManager.getAgentContext("agent-1")).toBeUndefined();
    });

    it("gets all active agents", () => {
      stateManager.registerAgent({
        agentId: "agent-1",
        agentType: "code-implementer-agent",
        startedAt: new Date().toISOString(),
      });
      stateManager.registerAgent({
        agentId: "agent-2",
        agentType: "ts-test-agent",
        startedAt: new Date().toISOString(),
      });
      
      const agents = stateManager.getActiveAgents();
      expect(agents.length).toBe(2);
    });

    it("finds agent by task ID", () => {
      stateManager.registerAgent({
        agentId: "agent-1",
        agentType: "code-implementer-agent",
        taskId: "T1",
        startedAt: new Date().toISOString(),
      });
      
      const agent = stateManager.findAgentByTaskId("T1");
      expect(agent?.agentId).toBe("agent-1");
    });
  });
});

// ============================================================================
// Factory Function Tests
// ============================================================================

describe("createStateManager", () => {
  it("creates StateManager instance", () => {
    const manager = createStateManager(testDir);
    expect(manager).toBeInstanceOf(StateManager);
  });
});

// ============================================================================
// Cross-Repo Session Tests
// ============================================================================

describe("cross-repo session support", () => {
  const sessionDir = "/tmp/opencode-subagents";
  const testSessionId = `test-session-${randomUUID()}`;

  afterEach(async () => {
    // Clean up session file
    await unregisterSessionTaskGraph(testSessionId);
  });

  describe("registerSessionTaskGraph", () => {
    it("creates session file with path", async () => {
      const taskGraphPath = join(testDir, ".opencode/state/active_task_graph.json");
      
      await registerSessionTaskGraph(testSessionId, taskGraphPath);
      
      const sessionFilePath = join(sessionDir, `${testSessionId}.task_graph`);
      expect(existsSync(sessionFilePath)).toBe(true);
      
      const content = await readFile(sessionFilePath, "utf-8");
      expect(content).toBe(taskGraphPath);
    });
  });

  describe("unregisterSessionTaskGraph", () => {
    it("removes session file", async () => {
      const taskGraphPath = join(testDir, ".opencode/state/active_task_graph.json");
      await registerSessionTaskGraph(testSessionId, taskGraphPath);
      
      await unregisterSessionTaskGraph(testSessionId);
      
      const sessionFilePath = join(sessionDir, `${testSessionId}.task_graph`);
      expect(existsSync(sessionFilePath)).toBe(false);
    });

    it("handles missing file gracefully", async () => {
      await expect(unregisterSessionTaskGraph("nonexistent")).resolves.not.toThrow();
    });
  });

  describe("resolveTaskGraphPath", () => {
    it("returns local path when no session file", async () => {
      // Create local task graph
      await stateManager.save(createTaskGraph());
      
      const resolved = await resolveTaskGraphPath(undefined, testDir);
      expect(resolved).toBe(join(testDir, ".opencode/state/active_task_graph.json"));
    });

    it("returns null when no task graph exists", async () => {
      const resolved = await resolveTaskGraphPath(undefined, testDir);
      expect(resolved).toBeNull();
    });

    it("prefers session path over local when session file exists", async () => {
      // Create session file pointing to a path within testDir (to avoid permission issues)
      const remotePath = join(testDir, "other-project/.opencode/state/active_task_graph.json");
      
      // Create the remote file for existence check
      await mkdir(join(testDir, "other-project/.opencode/state"), { recursive: true });
      await writeFile(remotePath, "{}");
      
      await registerSessionTaskGraph(testSessionId, remotePath);
      
      // Also create local
      await stateManager.save(createTaskGraph());
      
      const resolved = await resolveTaskGraphPath(testSessionId, testDir);
      expect(resolved).toBe(remotePath);
    });
  });
});
