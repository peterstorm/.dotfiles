/**
 * Store Review Findings Hook
 *
 * Parses review agent output for CRITICAL and ADVISORY markers.
 * Stores findings in the task graph for wave gate verification.
 *
 * CRITICAL findings block wave advancement.
 * ADVISORY findings are logged but don't block.
 *
 * This hook is called from message.updated when review content is detected.
 */
import type { TaskGraph, Task } from "../types.js";
import { StateManager } from "../utils/state-manager.js";
/**
 * Parsed review findings from agent output.
 */
export interface ReviewFindings {
    /** Task ID the review is for */
    taskId: string;
    /** Critical findings that block wave advancement */
    criticalFindings: string[];
    /** Advisory findings (non-blocking) */
    advisoryFindings: string[];
    /** Overall review verdict */
    verdict: "passed" | "blocked";
}
/**
 * Parse and store review findings from message content.
 *
 * Called when a message is detected to contain review output
 * (CRITICAL/ADVISORY markers or review agent completion signals).
 *
 * @param content - Message content to parse
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @param taskId - Optional explicit task ID (if known from context)
 * @returns Parsed findings, or null if no review content detected
 */
export declare function storeReviewFindings(content: string, taskGraph: TaskGraph, stateManager: StateManager, taskId?: string): Promise<ReviewFindings | null>;
/**
 * Extract CRITICAL findings from content.
 *
 * Matches patterns like:
 * - CRITICAL: Description of issue
 * - 🚨 CRITICAL: Description of issue
 */
export declare function extractCriticalFindings(content: string): string[];
/**
 * Extract ADVISORY findings from content.
 *
 * Matches patterns like:
 * - ADVISORY: Suggestion for improvement
 * - 💡 ADVISORY: Suggestion for improvement
 */
export declare function extractAdvisoryFindings(content: string): string[];
/**
 * Check if content indicates a review was completed.
 *
 * Used to detect review completions even when no findings are present.
 */
export declare function isReviewContent(content: string): boolean;
/**
 * Check if content indicates a passing review.
 *
 * Used to mark tasks as reviewed even when no issues are found.
 */
export declare function isReviewPassMessage(content: string): boolean;
/**
 * Check if an agent type is a review agent.
 */
export declare function isReviewAgent(agentType?: string): boolean;
/**
 * Count total critical findings across all tasks in a wave.
 */
export declare function countWaveCriticalFindings(taskGraph: TaskGraph, wave: number): number;
/**
 * Get all tasks with critical findings in a wave.
 */
export declare function getBlockedTasks(taskGraph: TaskGraph, wave: number): Task[];
/**
 * Check if all tasks in a wave have been reviewed.
 */
export declare function areAllTasksReviewed(taskGraph: TaskGraph, wave: number): boolean;
//# sourceMappingURL=store-review-findings.d.ts.map