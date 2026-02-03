/**
 * Complete Wave Gate Hook
 *
 * Verifies all wave gate requirements are met before advancing to next wave:
 * 1. All tasks have test evidence (tests_passed = true)
 * 2. All tasks that require new tests have them (new_tests_written = true)
 * 3. All tasks have been reviewed (review_status = passed | blocked)
 * 4. No critical review findings
 * 5. Spec alignment verified (optional)
 *
 * This hook is called by the /wave-gate skill.
 */
import type { TaskGraph, Task, WaveGateResult } from "../types.js";
import { StateManager } from "../utils/state-manager.js";
/**
 * Verify all wave gate requirements and optionally advance to next wave.
 *
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @param wave - Wave number to verify (defaults to current_wave)
 * @returns WaveGateResult with check details
 */
export declare function completeWaveGate(taskGraph: TaskGraph, stateManager: StateManager, wave?: number): Promise<WaveGateResult>;
/**
 * Check 1: All tasks have test evidence.
 */
export declare function checkTestEvidence(tasks: Task[]): {
    passed: boolean;
    failedTasks: string[];
};
/**
 * Check 2: All tasks that require new tests have them.
 *
 * Task passes if:
 * - new_tests_required === false, OR
 * - new_tests_written === true
 */
export declare function checkNewTests(tasks: Task[]): {
    passed: boolean;
    failedTasks: string[];
};
/**
 * Check 3: All tasks have been reviewed.
 *
 * Review status must be "passed" or "blocked" (not "pending" or undefined).
 */
export declare function checkReviews(tasks: Task[]): {
    passed: boolean;
    failedTasks: string[];
};
/**
 * Check 4: Spec alignment is verified.
 */
export declare function checkSpecAlignment(taskGraph: TaskGraph, wave: number): {
    passed: boolean;
};
/**
 * Check 5: No critical review findings in any task.
 */
export declare function checkCriticalFindings(tasks: Task[]): {
    passed: boolean;
    failedTasks: string[];
    totalFindings: number;
};
/**
 * Check if a wave's implementation is complete.
 *
 * All tasks must be "implemented" or "completed".
 */
export declare function isWaveImplementationComplete(taskGraph: TaskGraph, wave: number): boolean;
/**
 * Get wave gate status summary.
 */
export declare function getWaveGateStatus(taskGraph: TaskGraph, wave: number): {
    implComplete: boolean;
    testsPassed: boolean | null;
    reviewsComplete: boolean;
    blocked: boolean;
};
/**
 * Get maximum wave number in the task graph.
 */
export declare function getMaxWave(taskGraph: TaskGraph): number;
/**
 * Check if all waves are complete.
 */
export declare function areAllWavesComplete(taskGraph: TaskGraph): boolean;
//# sourceMappingURL=complete-wave-gate.d.ts.map