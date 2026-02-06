/**
 * Task Planner Plugin - Block Direct Edits Hook
 *
 * Prevents direct use of Edit/Write tools during orchestration.
 * All implementation must go through designated agents to ensure
 * proper phase sequencing and review gates.
 *
 * Equivalent to: ~/.claude/hooks/PreToolUse/block-direct-edits.sh
 */

import type { TaskGraph, ToolExecuteInput } from "../types";
import { BLOCKED_TOOLS, ERRORS } from "../constants";

// ============================================================================
// Hook Function
// ============================================================================

/**
 * Check if a tool invocation should be blocked during orchestration.
 *
 * @param input - The tool execution input
 * @param taskGraph - The active task graph (null if no orchestration active)
 * @throws Error if the tool is blocked
 */
export function blockDirectEdits(
  input: ToolExecuteInput,
  taskGraph: TaskGraph | null
): void {
  // No active orchestration = no blocking
  if (!taskGraph) {
    return;
  }

  // Normalize tool name for comparison
  const toolName = input.tool.toLowerCase();

  // Check if this is a blocked tool
  const isBlocked = BLOCKED_TOOLS.some(
    (blocked) => blocked.toLowerCase() === toolName
  );

  if (isBlocked) {
    throw new Error(ERRORS.DIRECT_EDIT_BLOCKED);
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/**
 * Check if orchestration is active (helper for external callers).
 */
export function isOrchestrationActive(taskGraph: TaskGraph | null): boolean {
  return taskGraph !== null;
}

/**
 * Get list of tools that are blocked during orchestration.
 */
export function getBlockedTools(): readonly string[] {
  return BLOCKED_TOOLS;
}
