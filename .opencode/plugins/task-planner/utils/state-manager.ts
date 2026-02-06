/**
 * Task Planner Plugin - State Manager
 *
 * Handles reading, writing, and locking of the task graph state file.
 * Provides atomic operations with file-based locking for concurrent access.
 * Supports cross-repo orchestration via session-scoped path resolution.
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
} from "../types";
import {
  STATE_DIR,
  TASK_GRAPH_FILENAME,
  LOCK_FILENAME,
  LOCK_TIMEOUT_MS,
  LOCK_RETRY_INTERVAL_MS,
  MAX_LOCK_ATTEMPTS,
  ERRORS,
} from "../constants";

// ============================================================================
// Cross-Repo Session Support
// ============================================================================

/** Directory for session-scoped task graph path files */
const SESSION_STATE_DIR = "/tmp/opencode-subagents";

/**
 * Resolve task graph path for cross-repo access.
 *
 * Priority:
 * 1. Session-scoped path (enables cross-repo access)
 * 2. Local path (same repo as orchestrator)
 *
 * This matches Claude Code's resolve-task-graph.sh behavior.
 *
 * @param sessionId - Current session ID
 * @param projectDir - Project directory to check for local path
 * @returns Resolved task graph path, or null if not found
 */
export async function resolveTaskGraphPath(
  sessionId: string | undefined,
  projectDir: string
): Promise<string | null> {
  // Priority 1: Session-scoped path (enables cross-repo access)
  if (sessionId) {
    const sessionFile = join(SESSION_STATE_DIR, `${sessionId}.task_graph`);
    if (existsSync(sessionFile)) {
      try {
        const absPath = (await readFile(sessionFile, "utf-8")).trim();
        if (existsSync(absPath)) {
          return absPath;
        }
      } catch {
        // Fall through to local path
      }
    }
  }

  // Priority 2: Local path (same repo as orchestrator)
  const localPath = join(projectDir, STATE_DIR, TASK_GRAPH_FILENAME);
  if (existsSync(localPath)) {
    return localPath;
  }

  return null;
}

/**
 * Register a task graph path for cross-repo session access.
 *
 * Creates a session-scoped file that maps session ID to task graph path,
 * allowing subagents in different repos to find the orchestrator's state.
 *
 * @param sessionId - Current session ID
 * @param taskGraphPath - Absolute path to task graph
 */
export async function registerSessionTaskGraph(
  sessionId: string,
  taskGraphPath: string
): Promise<void> {
  if (!existsSync(SESSION_STATE_DIR)) {
    await mkdir(SESSION_STATE_DIR, { recursive: true });
  }

  const sessionFile = join(SESSION_STATE_DIR, `${sessionId}.task_graph`);
  await writeFile(sessionFile, taskGraphPath);
}

/**
 * Unregister a session task graph path.
 *
 * Called when orchestration completes to clean up session state.
 *
 * @param sessionId - Session ID to unregister
 */
export async function unregisterSessionTaskGraph(
  sessionId: string
): Promise<void> {
  const sessionFile = join(SESSION_STATE_DIR, `${sessionId}.task_graph`);
  if (existsSync(sessionFile)) {
    await unlink(sessionFile);
  }
}

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
   *
   * Uses atomic mkdir for lock acquisition - this is cross-platform safe
   * and matches Claude Code's lock.sh behavior on macOS.
   * mkdir fails atomically if directory exists, preventing race conditions.
   */
  private async acquireLock(): Promise<void> {
    const maxAttempts = MAX_LOCK_ATTEMPTS;
    let attempt = 0;

    // Ensure parent directory exists
    const lockDir = dirname(this.lockPath);
    if (!existsSync(lockDir)) {
      await mkdir(lockDir, { recursive: true });
    }

    // Use .lock suffix on lockPath for atomic mkdir
    const atomicLockDir = `${this.lockPath}.d`;

    while (attempt < maxAttempts) {
      // Check if lock exists and is stale
      if (existsSync(atomicLockDir)) {
        try {
          const pidFile = join(atomicLockDir, "pid");
          if (existsSync(pidFile)) {
            const lockStat = await stat(pidFile);
            const lockAge = Date.now() - lockStat.mtimeMs;

            // If lock is older than timeout, consider it stale and remove
            if (lockAge > this.lockTimeout) {
              console.warn("[task-planner] Removing stale lock directory");
              await this.rmdir(atomicLockDir);
            }
          }
        } catch {
          // Lock directory may have been removed by another process
        }
      }

      // Try to acquire lock using atomic mkdir
      try {
        await mkdir(atomicLockDir); // Fails atomically if exists
        // Store PID for stale lock detection
        await writeFile(join(atomicLockDir, "pid"), `${process.pid}`);
        return; // Lock acquired
      } catch (err: unknown) {
        // EEXIST means another process has the lock
        if ((err as NodeJS.ErrnoException).code !== "EEXIST") {
          throw err;
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
    const atomicLockDir = `${this.lockPath}.d`;
    try {
      await this.rmdir(atomicLockDir);
    } catch (error) {
      console.warn("[task-planner] Failed to release lock:", error);
    }
  }

  /**
   * Recursively remove a directory.
   */
  private async rmdir(dir: string): Promise<void> {
    if (!existsSync(dir)) return;
    
    const { rm } = await import("fs/promises");
    await rm(dir, { recursive: true, force: true });
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

/**
 * Create a state manager with cross-repo session resolution.
 *
 * This factory function first resolves the task graph path using
 * session-scoped resolution, enabling subagents in different repos
 * to access the orchestrator's state.
 *
 * @param sessionId - Current session ID (for cross-repo resolution)
 * @param projectDir - Project directory (fallback for local resolution)
 * @returns StateManager if task graph found, null otherwise
 */
export async function createStateManagerForSession(
  sessionId: string | undefined,
  projectDir: string
): Promise<StateManager | null> {
  const resolvedPath = await resolveTaskGraphPath(sessionId, projectDir);

  if (!resolvedPath) {
    return null;
  }

  // Extract the project dir from the resolved path
  // e.g., /foo/bar/.opencode/state/active_task_graph.json -> /foo/bar
  const stateDir = dirname(resolvedPath); // .../state
  const configDir = dirname(stateDir); // .../.opencode
  const resolvedProjectDir = dirname(configDir); // ...

  return new StateManager({
    projectDir: resolvedProjectDir,
  });
}
