/**
 * Task Planner Plugin - Guard State File Hook
 *
 * Prevents Bash commands from writing to state files.
 * State files must be modified through the StateManager to ensure
 * proper locking and consistency.
 *
 * Equivalent to: ~/.claude/hooks/PreToolUse/guard-state-file.sh
 */
import { PROTECTED_STATE_PATTERNS, BASH_WRITE_PATTERNS, ERRORS, } from "../constants.js";
// ============================================================================
// Hook Function
// ============================================================================
/**
 * Check if a Bash command is attempting to write to a protected state file.
 *
 * @param input - The tool execution input
 * @param taskGraph - The active task graph (null if no orchestration active)
 * @throws Error if the command would write to a protected file
 */
export function guardStateFile(input, _taskGraph) {
    // Only check Bash tool invocations
    if (input.tool.toLowerCase() !== "bash") {
        return;
    }
    // No active orchestration = still protect state files
    // (state files should always be protected)
    const command = input.args.command ?? "";
    if (!command) {
        return;
    }
    // Check if command contains write operations
    const hasWriteOperation = BASH_WRITE_PATTERNS.some((pattern) => pattern.test(command));
    if (!hasWriteOperation) {
        return;
    }
    // Check if any protected state file is being targeted
    const targetedFile = findProtectedFileInCommand(command);
    if (targetedFile) {
        throw new Error(ERRORS.STATE_FILE_WRITE_BLOCKED(targetedFile));
    }
}
// ============================================================================
// Utility Functions
// ============================================================================
/**
 * Find if a command targets any protected state file.
 * Returns the matched file path or null.
 */
function findProtectedFileInCommand(command) {
    // Extract potential file paths from the command
    // This is a heuristic - we look for common path patterns
    const pathPatterns = [
        // Quoted paths
        /"([^"]+)"/g,
        /'([^']+)'/g,
        // Paths with .opencode or .claude
        /(?:\.opencode|\.claude)\/\S+/g,
        // Paths ending in .json or .md
        /\S+\.(?:json|md)\b/g,
    ];
    const potentialPaths = [];
    for (const pattern of pathPatterns) {
        const matches = command.matchAll(pattern);
        for (const match of matches) {
            // Use capture group if available, otherwise full match
            potentialPaths.push(match[1] ?? match[0]);
        }
    }
    // Check each potential path against protected patterns
    for (const path of potentialPaths) {
        for (const protectedPattern of PROTECTED_STATE_PATTERNS) {
            if (protectedPattern.test(path)) {
                return path;
            }
        }
    }
    return null;
}
/**
 * Check if a specific file path is protected.
 */
export function isProtectedPath(filePath) {
    return PROTECTED_STATE_PATTERNS.some((pattern) => pattern.test(filePath));
}
/**
 * Get the list of protected file patterns (for display/debugging).
 */
export function getProtectedPatterns() {
    return PROTECTED_STATE_PATTERNS;
}
/**
 * Extract all file paths mentioned in a Bash command.
 * Useful for debugging and logging.
 */
export function extractPathsFromCommand(command) {
    const paths = new Set();
    // Various patterns to extract paths
    const patterns = [
        // Quoted strings that look like paths
        /"((?:\/|\.\.?\/)[^"]+)"/g,
        /'((?:\/|\.\.?\/)[^']+)'/g,
        // Unquoted paths starting with / or ./
        /(?:^|\s)((?:\/|\.\.?\/)\S+)/gm,
        // Paths containing .opencode or .claude
        /\b(\S*(?:\.opencode|\.claude)\S*)/g,
    ];
    for (const pattern of patterns) {
        const matches = command.matchAll(pattern);
        for (const match of matches) {
            const path = (match[1] ?? match[0]).trim();
            if (path && path.length > 1) {
                paths.add(path);
            }
        }
    }
    return Array.from(paths);
}
//# sourceMappingURL=guard-state-file.js.map