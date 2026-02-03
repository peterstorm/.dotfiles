/**
 * Validate Task Execution Hook
 *
 * Enforces task execution rules for the Task tool:
 * 1. Wave order: Can't execute tasks from future waves
 * 2. Dependencies: Can't execute tasks with incomplete dependencies
 * 3. Review gate: Can't start new wave until previous wave's review gate passes
 *
 * This hook is called before the Task tool executes.
 */
import type { TaskGraph, Task, TaskToolInput, TaskExecutionResult } from "../types.js";
/**
 * Validate whether a task execution should be allowed.
 *
 * Checks wave order, dependencies, and review gate requirements.
 * Throws an error if execution should be blocked.
 *
 * @param input - The Task tool invocation input
 * @param taskGraph - Current task graph state (or null if none)
 * @returns TaskExecutionResult with validation details
 * @throws Error if validation fails (with detailed message for user)
 */
export declare function validateTaskExecution(input: TaskToolInput, taskGraph: TaskGraph | null): TaskExecutionResult;
/**
 * Check 1: Wave order validation.
 *
 * Tasks can only be executed if they're in the current wave or earlier.
 */
export declare function checkWaveOrder(task: Task, currentWave: number): TaskExecutionResult;
/**
 * Check 2: Dependency validation.
 *
 * All tasks in depends_on must be completed or implemented.
 */
export declare function checkDependencies(task: Task, allTasks: Task[]): TaskExecutionResult;
/**
 * Check 3: Review gate validation.
 *
 * Previous wave must have reviews_complete = true before starting current wave.
 */
export declare function checkReviewGate(prevWave: number, taskGraph: TaskGraph): TaskExecutionResult;
/**
 * Check if a task is ready to execute.
 *
 * A task is ready if:
 * - It's in the current wave or earlier
 * - All its dependencies are completed
 * - Previous wave's review gate passed (if applicable)
 */
export declare function isTaskReady(task: Task, taskGraph: TaskGraph): boolean;
/**
 * Get all tasks that are ready to execute in the current wave.
 *
 * Returns tasks that pass all validation checks.
 */
export declare function getReadyTasks(taskGraph: TaskGraph): Task[];
/**
 * Get remaining tasks in the current wave.
 *
 * Returns tasks that haven't been completed yet.
 */
export declare function getRemainingTasks(taskGraph: TaskGraph): Task[];
//# sourceMappingURL=validate-task-execution.d.ts.map