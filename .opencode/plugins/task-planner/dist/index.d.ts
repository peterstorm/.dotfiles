/**
 * Task Planner Plugin for OpenCode
 *
 * This plugin enforces structured task execution following the task-planner
 * workflow: brainstorm → specify → clarify → architecture → decompose → execute
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
import { StateManager } from "./utils/state-manager.js";
import type { ToolExecuteInput, TaskCompletionContext } from "./types.js";
/**
 * OpenCode plugin context passed to the plugin factory.
 */
interface PluginContext {
    /** Current project directory */
    directory: string;
    /** OpenCode version */
    version?: string;
}
/**
 * OpenCode plugin event handlers.
 */
interface PluginEventHandlers {
    /** Called before a tool executes */
    "tool.execute.before"?: (input: ToolExecuteInput) => Promise<void> | void;
    /** Called after a tool executes */
    "tool.execute.after"?: (input: ToolExecuteInput, result: unknown) => Promise<void> | void;
    /** Called when session becomes idle */
    "session.idle"?: (context: {
        sessionId: string;
    }) => Promise<void> | void;
    /** Called when a file is edited */
    "file.edited"?: (context: {
        path: string;
    }) => Promise<void> | void;
    /** Called when a message is updated */
    "message.updated"?: (context: {
        role: string;
        content: string;
    }) => Promise<void> | void;
}
/**
 * OpenCode plugin type.
 */
type Plugin = (ctx: PluginContext) => Promise<PluginEventHandlers>;
/**
 * Task Planner Plugin factory function.
 *
 * This is the main entry point that OpenCode calls to initialize the plugin.
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