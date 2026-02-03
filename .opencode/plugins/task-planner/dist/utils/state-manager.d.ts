/**
 * Task Planner Plugin - State Manager
 *
 * Handles reading, writing, and locking of the task graph state file.
 * Provides atomic operations with file-based locking for concurrent access.
 */
import type { TaskGraph, Task, TaskStatus, Phase, WaveGate, AgentContext, StateManagerOptions } from "../types.js";
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
     */
    private acquireLock;
    /**
     * Release the state file lock.
     */
    private releaseLock;
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
//# sourceMappingURL=state-manager.d.ts.map