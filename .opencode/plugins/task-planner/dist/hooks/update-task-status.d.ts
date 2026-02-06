/**
 * Update Task Status Hook
 *
 * Updates task status when an implementation agent completes.
 * Marks task as "implemented" (not "completed" - that happens after review gate).
 * Extracts test evidence from agent transcript for per-task test verification.
 *
 * This hook is called when an agent/task completes (SubagentStop equivalent).
 */
import type { TaskGraph, TaskCompletionContext, TestEvidence } from "../types.js";
import { StateManager } from "../utils/state-manager.js";
/**
 * Update task status when an agent completes.
 *
 * - Extracts task ID from transcript
 * - Extracts test evidence from output
 * - Marks task as "implemented"
 * - Updates executing_tasks list
 * - Checks if wave implementation is complete
 * - Handles crash detection for impl agents without task ID
 *
 * @param context - Task completion context with transcript and agent info
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @returns Updated task ID and status, or null if not a tracked task
 */
export declare function updateTaskStatus(context: TaskCompletionContext, taskGraph: TaskGraph, stateManager: StateManager): Promise<{
    taskId: string;
    testEvidence: TestEvidence;
    waveComplete: boolean;
    remainingTasks: string[];
} | null>;
/**
 * Extract test evidence from agent transcript/output.
 *
 * Supports multiple test frameworks:
 * - Maven (Java): "BUILD SUCCESS" + "Tests run: X, Failures: 0, Errors: 0"
 * - Mocha (Node): "N passing" without "N failing"
 * - Vitest: "Tests X passed" or "Test Files X passed"
 * - pytest: "X passed" without "X failed"
 */
export declare function extractTestEvidence(transcript: string): TestEvidence;
/**
 * Check if an agent type is a review agent.
 */
export declare function isReviewAgent(agentType?: string): boolean;
/**
 * Check if all tasks in a wave are implemented or completed.
 */
export declare function checkWaveComplete(wave: number, stateManager: StateManager): Promise<boolean>;
/**
 * Get task IDs that are not yet implemented in a wave.
 */
export declare function getRemainingTaskIds(taskGraph: TaskGraph, wave: number): string[];
/**
 * Parse files modified from agent transcript.
 *
 * Looks for patterns like:
 * - "Wrote to file: path/to/file.ts"
 * - "Modified: path/to/file.ts"
 * - "Created: path/to/file.ts"
 */
export declare function parseFilesModified(transcript: string): string[];
/**
 * Check if an agent type triggers crash detection.
 *
 * Only implementation agents (not review/utility agents) trigger crash detection.
 * If an impl agent completes without a parseable task ID, it likely crashed or
 * was killed mid-execution.
 */
export declare function isCrashDetectionAgent(agentType?: string): boolean;
//# sourceMappingURL=update-task-status.d.ts.map