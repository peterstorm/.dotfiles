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
// ============================================================================
// Patterns (ordered by preference)
// ============================================================================
/**
 * Pattern 1: Canonical **Task ID:** T1 or **Task ID: T1**
 */
const CANONICAL_PATTERN = /\*\*Task ID:\*\*\s?(T\d+)/i;
/**
 * Pattern 2: Plain Task ID: T1 (case insensitive)
 */
const PLAIN_TASK_ID_PATTERN = /Task ID:?\s?(T\d+)/i;
/**
 * Pattern 3: Task: T1 (missing "ID")
 */
const TASK_COLON_PATTERN = /Task:?\s?(T\d+)/i;
/**
 * Pattern 4: Description starting with "T1 -" or "T1:"
 */
const DESCRIPTION_START_PATTERN = /^(T\d+)[:\s-]/;
/**
 * Pattern 5: Verb + T1 (implement T1, fix T1, complete T1, etc)
 */
const VERB_TASK_PATTERN = /(?:implement|fix|complete|execute|run|start|do|work(?:ing)?\s+on)\s+(T\d+)/i;
/**
 * Pattern 6: T1 followed by descriptive text (e.g., "T3 Create new component")
 */
const TASK_DESCRIPTION_PATTERN = /(T\d+)\s+[A-Z]/;
/**
 * Pattern 7: Standalone T1 anywhere (last resort - matches first T# found)
 */
const STANDALONE_PATTERN = /\b(T\d+)\b/;
// ============================================================================
// Main Functions
// ============================================================================
/**
 * Extract task ID from prompt text with flexible pattern matching.
 *
 * Tries patterns in order of preference, returning the first match.
 * Returns null if no task ID is found.
 *
 * @param text - The prompt or description text to search
 * @returns The task ID (e.g., "T1") or null
 */
export function extractTaskId(text) {
    if (!text)
        return null;
    // Pattern 1: Canonical **Task ID:** T1
    const canonical = text.match(CANONICAL_PATTERN);
    if (canonical?.[1])
        return canonical[1].toUpperCase();
    // Pattern 2: Plain Task ID: T1
    const plainTaskId = text.match(PLAIN_TASK_ID_PATTERN);
    if (plainTaskId?.[1])
        return plainTaskId[1].toUpperCase();
    // Pattern 3: Task: T1
    const taskColon = text.match(TASK_COLON_PATTERN);
    if (taskColon?.[1])
        return taskColon[1].toUpperCase();
    // Pattern 4: Description starting with "T1 -"
    const descStart = text.match(DESCRIPTION_START_PATTERN);
    if (descStart?.[1])
        return descStart[1].toUpperCase();
    // Pattern 5: Verb + T1
    const verbTask = text.match(VERB_TASK_PATTERN);
    if (verbTask?.[1])
        return verbTask[1].toUpperCase();
    // Pattern 6: T1 followed by descriptive text
    const taskDesc = text.match(TASK_DESCRIPTION_PATTERN);
    if (taskDesc?.[1])
        return taskDesc[1].toUpperCase();
    // Pattern 7: Standalone T1 (last resort)
    const standalone = text.match(STANDALONE_PATTERN);
    if (standalone?.[1])
        return standalone[1].toUpperCase();
    return null;
}
/**
 * Extract task ID from a TaskToolInput's prompt or description.
 *
 * Tries the prompt first, then falls back to description.
 *
 * @param args - Tool arguments containing prompt and/or description
 * @returns The task ID (e.g., "T1") or null
 */
export function extractTaskIdFromArgs(args) {
    // Try prompt first
    if (args.prompt) {
        const fromPrompt = extractTaskId(args.prompt);
        if (fromPrompt)
            return fromPrompt;
    }
    // Fall back to description
    if (args.description) {
        const fromDesc = extractTaskId(args.description);
        if (fromDesc)
            return fromDesc;
    }
    return null;
}
// ============================================================================
// Validation Functions
// ============================================================================
/**
 * Check if a task ID uses the canonical format.
 *
 * @param text - The text to check
 * @returns true if canonical format is used, false otherwise
 */
export function isCanonicalFormat(text) {
    return CANONICAL_PATTERN.test(text);
}
/**
 * Get the canonical format for a task ID.
 *
 * @param taskId - The task ID (e.g., "T1")
 * @returns The canonical format string (e.g., "**Task ID:** T1")
 */
export function getCanonicalFormat(taskId) {
    return `**Task ID:** ${taskId.toUpperCase()}`;
}
/**
 * Validate task ID format and return status.
 *
 * @param text - The text to validate
 * @returns 'canonical' | 'valid' | 'none'
 */
export function validateTaskIdFormat(text) {
    if (isCanonicalFormat(text)) {
        return "canonical";
    }
    if (extractTaskId(text)) {
        return "valid";
    }
    return "none";
}
// ============================================================================
// Multiple Task ID Extraction
// ============================================================================
/**
 * Extract all task IDs from text.
 *
 * Useful for parsing lists of tasks or dependencies.
 *
 * @param text - The text to search
 * @returns Array of unique task IDs found
 */
export function extractAllTaskIds(text) {
    if (!text)
        return [];
    const matches = text.matchAll(/\b(T\d+)\b/gi);
    const taskIds = [...matches]
        .map((m) => m[1])
        .filter((id) => id !== undefined)
        .map((id) => id.toUpperCase());
    // Return unique IDs in order of first appearance
    return [...new Set(taskIds)];
}
//# sourceMappingURL=task-id-extractor.js.map