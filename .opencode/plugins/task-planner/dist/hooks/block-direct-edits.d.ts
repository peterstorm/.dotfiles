/**
 * Task Planner Plugin - Block Direct Edits Hook
 *
 * Prevents direct use of Edit/Write tools during orchestration.
 * All implementation must go through designated agents to ensure
 * proper phase sequencing and review gates.
 *
 * Equivalent to: ~/.claude/hooks/PreToolUse/block-direct-edits.sh
 */
import type { TaskGraph, ToolExecuteInput } from "../types.js";
/**
 * Check if a tool invocation should be blocked during orchestration.
 *
 * @param input - The tool execution input
 * @param taskGraph - The active task graph (null if no orchestration active)
 * @throws Error if the tool is blocked
 */
export declare function blockDirectEdits(input: ToolExecuteInput, taskGraph: TaskGraph | null): void;
/**
 * Check if orchestration is active (helper for external callers).
 */
export declare function isOrchestrationActive(taskGraph: TaskGraph | null): boolean;
/**
 * Get list of tools that are blocked during orchestration.
 */
export declare function getBlockedTools(): readonly string[];
//# sourceMappingURL=block-direct-edits.d.ts.map