/**
 * Task Planner Plugin - State Manager
 *
 * Handles reading, writing, and locking of the task graph state file.
 * Provides atomic operations with file-based locking for concurrent access.
 * Supports cross-repo orchestration via session-scoped path resolution.
 */
import type { TaskGraph, Task, TaskStatus, Phase, WaveGate, AgentContext, StateManagerOptions } from "../types.js";
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
export declare function resolveTaskGraphPath(sessionId: string | undefined, projectDir: string): Promise<string | null>;
/**
 * Register a task graph path for cross-repo session access.
 *
 * Creates a session-scoped file that maps session ID to task graph path,
 * allowing subagents in different repos to find the orchestrator's state.
 *
 * @param sessionId - Current session ID
 * @param taskGraphPath - Absolute path to task graph
 */
export declare function registerSessionTaskGraph(sessionId: string, taskGraphPath: string): Promise<void>;
/**
 * Unregister a session task graph path.
 *
 * Called when orchestration completes to clean up session state.
 *
 * @param sessionId - Session ID to unregister
 */
export declare function unregisterSessionTaskGraph(sessionId: string): Promise<void>;
export declare class StateManager {
    private readonly statePath;
    private readonly lockPath;
    private readonly lockTimeout;
    /** In-memory tracking of files modified during this session */
    private filesModified;
    /** In-memory tracking of active agents */
    private activeAgents;
    constructor(options: StateManagerOptions | string);
    /**
     * Load the task graph from disk.
     * Returns null if no active task graph exists.
     */
    load(): Promise<TaskGraph | null>;
    /**
     * Save the task graph to disk with locking.
     */
    save(taskGraph: TaskGraph): Promise<void>;
    /**
     * Check if there's an active task graph.
     */
    hasActiveTaskGraph(): Promise<boolean>;
    /**
     * Delete the task graph (mark plan as complete).
     */
    clear(): Promise<void>;
    /**
     * Get a specific task by ID.
     */
    getTask(taskId: string): Promise<Task | null>;
    /**
     * Update a specific task's properties.
     */
    updateTask(taskId: string, updates: Partial<Task>): Promise<void>;
    /**
     * Update multiple tasks at once.
     */
    updateTasks(updates: Array<{
        taskId: string;
        updates: Partial<Task>;
    }>): Promise<void>;
    /**
     * Set a task's status.
     */
    setTaskStatus(taskId: string, status: TaskStatus): Promise<void>;
    /**
     * Get all tasks in a specific wave.
     */
    getWaveTasks(wave: number): Promise<Task[]>;
    /**
     * Check if all dependencies for a task are satisfied.
     */
    checkDependencies(taskId: string): Promise<{
        satisfied: boolean;
        unmetDeps: string[];
    }>;
    /**
     * Get the current phase.
     */
    getCurrentPhase(): Promise<Phase | null>;
    /**
     * Set the current phase.
     */
    setCurrentPhase(phase: Phase): Promise<void>;
    /**
     * Record a phase artifact.
     */
    setPhaseArtifact(phase: Phase, artifactPath: string): Promise<void>;
    /**
     * Get the list of skipped phases.
     */
    getSkippedPhases(): Promise<Phase[]>;
    /**
     * Add a phase to the skipped phases list.
     * Does nothing if the phase is already in the list.
     */
    addSkippedPhase(phase: Phase): Promise<void>;
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
    advancePhase(completedPhase: Phase, nextPhase: Phase, artifact: string): Promise<void>;
    /**
     * Get artifact path for a phase.
     *
     * @param phase - The phase to get artifact for
     * @returns The artifact path, or null if not set
     */
    getPhaseArtifact(phase: Phase): Promise<string | null>;
    /**
     * Check if an artifact file exists on disk.
     *
     * Handles the special case where artifact is "completed" (no file required).
     *
     * @param artifactPath - Relative path to the artifact
     * @param projectDir - Project directory for resolving the path
     * @returns true if artifact exists or is "completed"
     */
    checkArtifactExists(artifactPath: string, projectDir: string): Promise<boolean>;
    /**
     * Get the current wave number.
     */
    getCurrentWave(): Promise<number>;
    /**
     * Advance to the next wave.
     */
    advanceWave(): Promise<number>;
    /**
     * Update wave gate status.
     */
    updateWaveGate(wave: number, updates: Partial<WaveGate>): Promise<void>;
    /**
     * Check if the current wave is complete.
     */
    isWaveComplete(wave: number): Promise<boolean>;
    /**
     * Mark a task as currently executing.
     */
    markTaskExecuting(taskId: string): Promise<void>;
    /**
     * Mark a task as no longer executing.
     */
    unmarkTaskExecuting(taskId: string): Promise<void>;
    /**
     * Track a file that was modified.
     */
    trackFileEdit(path: string): void;
    /**
     * Get all tracked file modifications.
     */
    getFilesModified(): string[];
    /**
     * Clear tracked file modifications.
     */
    clearFilesModified(): void;
    /**
     * Register an active agent.
     */
    registerAgent(context: AgentContext): void;
    /**
     * Unregister an agent.
     */
    unregisterAgent(agentId: string): void;
    /**
     * Get an active agent's context.
     */
    getAgentContext(agentId: string): AgentContext | undefined;
    /**
     * Get all active agents.
     */
    getActiveAgents(): AgentContext[];
    /**
     * Find agent by task ID.
     */
    findAgentByTaskId(taskId: string): AgentContext | undefined;
    /**
     * Execute a function with exclusive lock on the state file.
     */
    private withLock;
    /**
     * Acquire the state file lock.
     *
     * Uses atomic mkdir for lock acquisition - this is cross-platform safe
     * and matches Claude Code's lock.sh behavior on macOS.
     * mkdir fails atomically if directory exists, preventing race conditions.
     */
    private acquireLock;
    /**
     * Release the state file lock.
     */
    private releaseLock;
    /**
     * Recursively remove a directory.
     */
    private rmdir;
    /**
     * Load without acquiring lock (for use within withLock).
     */
    private loadUnsafe;
    /**
     * Save without acquiring lock (for use within withLock).
     */
    private saveUnsafe;
    /**
     * Sleep helper.
     */
    private sleep;
}
/**
 * Create a state manager for the given project directory.
 */
export declare function createStateManager(projectDir: string): StateManager;
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
export declare function createStateManagerForSession(sessionId: string | undefined, projectDir: string): Promise<StateManager | null>;
//# sourceMappingURL=state-manager.d.ts.map