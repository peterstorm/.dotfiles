/**
 * Task Planner Plugin for OpenCode
 *
 * This plugin enforces structured task execution following the task-planner
 * workflow: brainstorm -> specify -> clarify -> architecture -> decompose -> execute
 *
 * It provides:
 * - Blocking of direct Edit/Write during orchestration (Phase 1)
 * - Protection of state files from Bash writes (Phase 1)
 * - Phase transition validation (Phase 2)
 * - Task execution validation (wave order, dependencies, review gate) (Phase 3)
 * - Task status updates and test evidence capture (Phase 3)
 * - New test verification (Phase 3)
 * - Review findings capture (CRITICAL/ADVISORY markers) (Phase 4)
 * - Spec-check parsing (Phase 4)
 *
 * Converted from Claude Code hooks to OpenCode plugin system.
 */
import type { Plugin } from "@opencode-ai/plugin";
import { StateManager } from "./utils/state-manager.js";
export { completeWaveGate, isWaveImplementationComplete, } from "./hooks/complete-wave-gate.js";
import type { TaskCompletionContext } from "./types.js";
/**
 * Task Planner Plugin factory function.
 *
 * This is the main entry point that OpenCode calls to initialize the plugin.
 * Uses the official @opencode-ai/plugin types.
 */
export declare const TaskPlannerPlugin: Plugin;
/**
 * Invalidate the task graph cache.
 * Call this after any state modifications.
 */
export declare function invalidateCache(): void;
/**
 * Get the state manager instance (for external access if needed).
 */
export declare function getStateManager(): StateManager | null;
/**
 * Get the current task context (for testing/debugging).
 */
export declare function getCurrentTaskContext(): TaskCompletionContext | null;
export default TaskPlannerPlugin;
//# sourceMappingURL=index.d.ts.map