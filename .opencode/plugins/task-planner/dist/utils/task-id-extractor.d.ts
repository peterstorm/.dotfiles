/**
 * Task ID Extractor
 *
 * Extracts task IDs from prompts and descriptions using flexible pattern matching.
 * Mirrors the behavior of the bash helper extract-task-id.sh.
 *
 * Patterns matched (in order of preference):
 *   1. **Task ID:** T1    (canonical - markdown bold)
 *   2. Task ID: T1        (plain)
 *   3. Task: T1           (colon variant)
 *   4. Task T1            (no colon/ID)
 *   5. "T1 -" or "T1:"    (ID at description start)
 *   6. implement/fix/etc T1 (verb + task)
 *   7. Standalone T1      (bare task ID anywhere)
 */
/**
 * Extract task ID from prompt text with flexible pattern matching.
 *
 * Tries patterns in order of preference, returning the first match.
 * Returns null if no task ID is found.
 *
 * @param text - The prompt or description text to search
 * @returns The task ID (e.g., "T1") or null
 */
export declare function extractTaskId(text: string): string | null;
/**
 * Extract task ID from a TaskToolInput's prompt or description.
 *
 * Tries the prompt first, then falls back to description.
 *
 * @param args - Tool arguments containing prompt and/or description
 * @returns The task ID (e.g., "T1") or null
 */
export declare function extractTaskIdFromArgs(args: {
    prompt?: string;
    description?: string;
}): string | null;
/**
 * Check if a task ID uses the canonical format.
 *
 * @param text - The text to check
 * @returns true if canonical format is used, false otherwise
 */
export declare function isCanonicalFormat(text: string): boolean;
/**
 * Get the canonical format for a task ID.
 *
 * @param taskId - The task ID (e.g., "T1")
 * @returns The canonical format string (e.g., "**Task ID:** T1")
 */
export declare function getCanonicalFormat(taskId: string): string;
/**
 * Validate task ID format and return status.
 *
 * @param text - The text to validate
 * @returns 'canonical' | 'valid' | 'none'
 */
export declare function validateTaskIdFormat(text: string): "canonical" | "valid" | "none";
/**
 * Extract all task IDs from text.
 *
 * Useful for parsing lists of tasks or dependencies.
 *
 * @param text - The text to search
 * @returns Array of unique task IDs found
 */
export declare function extractAllTaskIds(text: string): string[];
//# sourceMappingURL=task-id-extractor.d.ts.map