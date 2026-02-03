/**
 * Task Planner Plugin - Guard State File Hook
 *
 * Prevents Bash commands from writing to state files.
 * State files must be modified through the StateManager to ensure
 * proper locking and consistency.
 *
 * Equivalent to: ~/.claude/hooks/PreToolUse/guard-state-file.sh
 */
import type { TaskGraph, ToolExecuteInput } from "../types.js";
/**
 * Check if a Bash command is attempting to write to a protected state file.
 *
 * @param input - The tool execution input
 * @param taskGraph - The active task graph (null if no orchestration active)
 * @throws Error if the command would write to a protected file
 */
export declare function guardStateFile(input: ToolExecuteInput, _taskGraph: TaskGraph | null): void;
/**
 * Check if a specific file path is protected.
 */
export declare function isProtectedPath(filePath: string): boolean;
/**
 * Get the list of protected file patterns (for display/debugging).
 */
export declare function getProtectedPatterns(): readonly RegExp[];
/**
 * Extract all file paths mentioned in a Bash command.
 * Useful for debugging and logging.
 */
export declare function extractPathsFromCommand(command: string): string[];
//# sourceMappingURL=guard-state-file.d.ts.map