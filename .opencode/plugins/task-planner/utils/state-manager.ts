/**
 * Task Planner Plugin - State Manager
 *
 * Handles reading, writing, and locking of the task graph state file.
 * Provides atomic operations with file-based locking for concurrent access.
 */

import { readFile, writeFile, mkdir, unlink, stat } from "fs/promises";
import { existsSync } from "fs";
import { join, dirname } from "path";
import type {
  TaskGraph,
  Task,
  TaskStatus,
  Phase,
  WaveGate,
  AgentContext,
  StateManagerOptions,
} from "../types.js";
import {
  STATE_DIR,
  TASK_GRAPH_FILENAME,
  LOCK_FILENAME,
  LOCK_TIMEOUT_MS,
  LOCK_RETRY_INTERVAL_MS,
  MAX_LOCK_ATTEMPTS,
  ERRORS,
} from "../constants.js";

// ============================================================================
// State Manager Class
// ============================================================================

export class StateManager {
  private readonly statePath: string;
  private readonly lockPath: string;
  private readonly lockTimeout: number;

  /** In-memory tracking of files modified during this session */
  private filesModified: Set<string> = new Set();

  /** In-memory tracking of active agents */
  private activeAgents: Map<string, AgentContext> = new Map();

  constructor(options: StateManagerOptions | string) {
    const opts: StateManagerOptions =
      typeof options === "string" ? { projectDir: options } : options;

    const stateDir = opts.stateDir ?? STATE_DIR;
    this.statePath = join(opts.projectDir, stateDir, TASK_GRAPH_FILENAME);
    this.lockPath = join(opts.projectDir, stateDir, LOCK_FILENAME);
    this.lockTimeout = opts.lockTimeout ?? LOCK_TIMEOUT_MS;
  }

  // ==========================================================================
  // Core State Operations
  // ==========================================================================

  /**
   * Load the task graph from disk.
   * Returns null if no active task graph exists.
   */
  async load(): Promise<TaskGraph | null> {
    if (!existsSync(this.statePath)) {
      return null;
    }

    try {
      const content = await readFile(this.statePath, "utf-8");
      return JSON.parse(content) as TaskGraph;
    } catch (error) {
      console.error("[task-planner] Failed to load state:", error);
      return null;
    }
  }

  /**
   * Save the task graph to disk with locking.
   */
  async save(taskGraph: TaskGraph): Promise<void> {
    await this.withLock(async () => {
      const dir = dirname(this.statePath);
      if (!existsSync(dir)) {
        await mkdir(dir, { recursive: true });
      }

      taskGraph.updated_at = new Date().toISOString();
      await writeFile(this.statePath, JSON.stringify(taskGraph, null, 2));
    });
  }

  /**
   * Check if there's an active task graph.
   */
  async hasActiveTaskGraph(): Promise<boolean> {
    return existsSync(this.statePath);
  }

  /**
   * Delete the task graph (mark plan as complete).
   */
  async clear(): Promise<void> {
    await this.withLock(async () => {
      if (existsSync(this.statePath)) {
        await unlink(this.statePath);
      }
    });
  }

  // ==========================================================================
  // Task Operations
  // ==========================================================================

  /**
   * Get a specific task by ID.
   */
  async getTask(taskId: string): Promise<Task | null> {
    const taskGraph = await this.load();
    if (!taskGraph) return null;
    return taskGraph.tasks.find((t) => t.id === taskId) ?? null;
  }

  /**
   * Update a specific task's properties.
   */
  async updateTask(taskId: string, updates: Partial<Task>): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.tasks = taskGraph.tasks.map((task) =>
        task.id === taskId ? { ...task, ...updates } : task
      );

      await this.saveUnsafe(taskGraph);
    });
  }

  /**
   * Update multiple tasks at once.
   */
  async updateTasks(
    updates: Array<{ taskId: string; updates: Partial<Task> }>
  ): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      const updateMap = new Map(updates.map((u) => [u.taskId, u.updates]));

      taskGraph.tasks = taskGraph.tasks.map((task) => {
        const taskUpdates = updateMap.get(task.id);
        return taskUpdates ? { ...task, ...taskUpdates } : task;
      });

      await this.saveUnsafe(taskGraph);
    });
  }

  /**
   * Set a task's status.
   */
  async setTaskStatus(taskId: string, status: TaskStatus): Promise<void> {
    await this.updateTask(taskId, { status });
  }

  /**
   * Get all tasks in a specific wave.
   */
  async getWaveTasks(wave: number): Promise<Task[]> {
    const taskGraph = await this.load();
    if (!taskGraph) return [];
    return taskGraph.tasks.filter((t) => t.wave === wave);
  }

  /**
   * Check if all dependencies for a task are satisfied.
   */
  async checkDependencies(taskId: string): Promise<{
    satisfied: boolean;
    unmetDeps: string[];
  }> {
    const taskGraph = await this.load();
    if (!taskGraph) return { satisfied: true, unmetDeps: [] };

    const task = taskGraph.tasks.find((t) => t.id === taskId);
    if (!task) return { satisfied: true, unmetDeps: [] };

    const completedStatuses: TaskStatus[] = ["implemented", "completed"];
    const unmetDeps = task.depends_on.filter((depId) => {
      const depTask = taskGraph.tasks.find((t) => t.id === depId);
      return !depTask || !completedStatuses.includes(depTask.status);
    });

    return {
      satisfied: unmetDeps.length === 0,
      unmetDeps,
    };
  }

  // ==========================================================================
  // Phase Operations
  // ==========================================================================

  /**
   * Get the current phase.
   */
  async getCurrentPhase(): Promise<Phase | null> {
    const taskGraph = await this.load();
    return taskGraph?.current_phase ?? null;
  }

  /**
   * Set the current phase.
   */
  async setCurrentPhase(phase: Phase): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.current_phase = phase;
      await this.saveUnsafe(taskGraph);
    });
  }

  /**
   * Record a phase artifact.
   */
  async setPhaseArtifact(phase: Phase, artifactPath: string): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.phase_artifacts = taskGraph.phase_artifacts ?? {};
      taskGraph.phase_artifacts[phase] = artifactPath;
      await this.saveUnsafe(taskGraph);
    });
  }

  // ==========================================================================
  // Phase 2: Advanced Phase Operations
  // ==========================================================================

  /**
   * Get the list of skipped phases.
   */
  async getSkippedPhases(): Promise<Phase[]> {
    const taskGraph = await this.load();
    return taskGraph?.skipped_phases ?? [];
  }

  /**
   * Add a phase to the skipped phases list.
   * Does nothing if the phase is already in the list.
   */
  async addSkippedPhase(phase: Phase): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.skipped_phases = taskGraph.skipped_phases ?? [];
      if (!taskGraph.skipped_phases.includes(phase)) {
        taskGraph.skipped_phases.push(phase);
        console.log(`[task-planner] Marked phase as skipped: ${phase}`);
      }
      await this.saveUnsafe(taskGraph);
    });
  }

  /**
   * Atomically advance to the next phase and record artifact.
   *
   * This updates both current_phase and phase_artifacts in a single
   * locked operation to prevent race conditions.
   *
   * @param completedPhase - The phase that was just completed
   * @param nextPhase - The phase to transition to
   * @param artifact - The artifact path or "completed" if no file
   */
  async advancePhase(
    completedPhase: Phase,
    nextPhase: Phase,
    artifact: string
  ): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.current_phase = nextPhase;
      taskGraph.phase_artifacts = taskGraph.phase_artifacts ?? {};
      taskGraph.phase_artifacts[completedPhase] = artifact;

      console.log(
        `[task-planner] Phase advanced: ${completedPhase} → ${nextPhase} (artifact: ${artifact})`
      );

      await this.saveUnsafe(taskGraph);
    });
  }

  /**
   * Get artifact path for a phase.
   *
   * @param phase - The phase to get artifact for
   * @returns The artifact path, or null if not set
   */
  async getPhaseArtifact(phase: Phase): Promise<string | null> {
    const taskGraph = await this.load();
    return taskGraph?.phase_artifacts?.[phase] ?? null;
  }

  /**
   * Check if an artifact file exists on disk.
   *
   * Handles the special case where artifact is "completed" (no file required).
   *
   * @param artifactPath - Relative path to the artifact
   * @param projectDir - Project directory for resolving the path
   * @returns true if artifact exists or is "completed"
   */
  async checkArtifactExists(
    artifactPath: string,
    projectDir: string
  ): Promise<boolean> {
    // "completed" is valid without a file
    if (!artifactPath || artifactPath === "completed") {
      return true;
    }

    const fullPath = join(projectDir, artifactPath);
    return existsSync(fullPath);
  }

  // ==========================================================================
  // Wave Operations
  // ==========================================================================

  /**
   * Get the current wave number.
   */
  async getCurrentWave(): Promise<number> {
    const taskGraph = await this.load();
    return taskGraph?.current_wave ?? 1;
  }

  /**
   * Advance to the next wave.
   */
  async advanceWave(): Promise<number> {
    let newWave = 1;

    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.current_wave += 1;
      newWave = taskGraph.current_wave;
      await this.saveUnsafe(taskGraph);
    });

    return newWave;
  }

  /**
   * Update wave gate status.
   */
  async updateWaveGate(wave: number, updates: Partial<WaveGate>): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.wave_gates = taskGraph.wave_gates ?? {};
      taskGraph.wave_gates[wave] = {
        ...taskGraph.wave_gates[wave],
        ...updates,
        checked_at: new Date().toISOString(),
      };
      await this.saveUnsafe(taskGraph);
    });
  }

  /**
   * Check if the current wave is complete.
   */
  async isWaveComplete(wave: number): Promise<boolean> {
    const tasks = await this.getWaveTasks(wave);
    return tasks.every((t) =>
      ["implemented", "completed"].includes(t.status)
    );
  }

  // ==========================================================================
  // Executing Tasks Tracking
  // ==========================================================================

  /**
   * Mark a task as currently executing.
   */
  async markTaskExecuting(taskId: string): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.executing_tasks = taskGraph.executing_tasks ?? [];
      if (!taskGraph.executing_tasks.includes(taskId)) {
        taskGraph.executing_tasks.push(taskId);
      }
      await this.saveUnsafe(taskGraph);
    });
  }

  /**
   * Mark a task as no longer executing.
   */
  async unmarkTaskExecuting(taskId: string): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.loadUnsafe();
      if (!taskGraph) return;

      taskGraph.executing_tasks = (taskGraph.executing_tasks ?? []).filter(
        (id) => id !== taskId
      );
      await this.saveUnsafe(taskGraph);
    });
  }

  // ==========================================================================
  // File Tracking (In-Memory)
  // ==========================================================================

  /**
   * Track a file that was modified.
   */
  trackFileEdit(path: string): void {
    this.filesModified.add(path);
  }

  /**
   * Get all tracked file modifications.
   */
  getFilesModified(): string[] {
    return Array.from(this.filesModified);
  }

  /**
   * Clear tracked file modifications.
   */
  clearFilesModified(): void {
    this.filesModified.clear();
  }

  // ==========================================================================
  // Agent Tracking (In-Memory)
  // ==========================================================================

  /**
   * Register an active agent.
   */
  registerAgent(context: AgentContext): void {
    this.activeAgents.set(context.agentId, context);
  }

  /**
   * Unregister an agent.
   */
  unregisterAgent(agentId: string): void {
    this.activeAgents.delete(agentId);
  }

  /**
   * Get an active agent's context.
   */
  getAgentContext(agentId: string): AgentContext | undefined {
    return this.activeAgents.get(agentId);
  }

  /**
   * Get all active agents.
   */
  getActiveAgents(): AgentContext[] {
    return Array.from(this.activeAgents.values());
  }

  /**
   * Find agent by task ID.
   */
  findAgentByTaskId(taskId: string): AgentContext | undefined {
    return Array.from(this.activeAgents.values()).find(
      (a) => a.taskId === taskId
    );
  }

  // ==========================================================================
  // File Locking
  // ==========================================================================

  /**
   * Execute a function with exclusive lock on the state file.
   */
  private async withLock<T>(fn: () => Promise<T>): Promise<T> {
    await this.acquireLock();

    try {
      return await fn();
    } finally {
      await this.releaseLock();
    }
  }

  /**
   * Acquire the state file lock.
   */
  private async acquireLock(): Promise<void> {
    const maxAttempts = MAX_LOCK_ATTEMPTS;
    let attempt = 0;

    // Ensure lock directory exists
    const lockDir = dirname(this.lockPath);
    if (!existsSync(lockDir)) {
      await mkdir(lockDir, { recursive: true });
    }

    while (attempt < maxAttempts) {
      // Check if lock exists and is stale
      if (existsSync(this.lockPath)) {
        try {
          const lockStat = await stat(this.lockPath);
          const lockAge = Date.now() - lockStat.mtimeMs;

          // If lock is older than timeout, consider it stale and remove
          if (lockAge > this.lockTimeout) {
            console.warn("[task-planner] Removing stale lock file");
            await unlink(this.lockPath);
          }
        } catch {
          // Lock file may have been removed by another process
        }
      }

      // Try to acquire lock
      if (!existsSync(this.lockPath)) {
        try {
          await writeFile(this.lockPath, `${process.pid}\n${Date.now()}`);
          return; // Lock acquired
        } catch {
          // Another process may have grabbed the lock
        }
      }

      attempt++;
      await this.sleep(LOCK_RETRY_INTERVAL_MS);
    }

    throw new Error(ERRORS.LOCK_ACQUISITION_FAILED);
  }

  /**
   * Release the state file lock.
   */
  private async releaseLock(): Promise<void> {
    try {
      if (existsSync(this.lockPath)) {
        await unlink(this.lockPath);
      }
    } catch (error) {
      console.warn("[task-planner] Failed to release lock:", error);
    }
  }

  /**
   * Load without acquiring lock (for use within withLock).
   */
  private async loadUnsafe(): Promise<TaskGraph | null> {
    if (!existsSync(this.statePath)) {
      return null;
    }

    try {
      const content = await readFile(this.statePath, "utf-8");
      return JSON.parse(content) as TaskGraph;
    } catch {
      return null;
    }
  }

  /**
   * Save without acquiring lock (for use within withLock).
   */
  private async saveUnsafe(taskGraph: TaskGraph): Promise<void> {
    const dir = dirname(this.statePath);
    if (!existsSync(dir)) {
      await mkdir(dir, { recursive: true });
    }

    taskGraph.updated_at = new Date().toISOString();
    await writeFile(this.statePath, JSON.stringify(taskGraph, null, 2));
  }

  /**
   * Sleep helper.
   */
  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

// ============================================================================
// Factory Function
// ============================================================================

/**
 * Create a state manager for the given project directory.
 */
export function createStateManager(projectDir: string): StateManager {
  return new StateManager({ projectDir });
}
