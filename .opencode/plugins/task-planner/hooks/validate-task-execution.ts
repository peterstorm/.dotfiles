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

import type {
  TaskGraph,
  Task,
  TaskToolInput,
  TaskExecutionResult,
  WaveGate,
} from "../types";
import { extractTaskIdFromArgs } from "../utils/task-id-extractor";
import { COMPLETED_TASK_STATUSES, ERRORS } from "../constants";

// ============================================================================
// Main Validation Function
// ============================================================================

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
export function validateTaskExecution(
  input: TaskToolInput,
  taskGraph: TaskGraph | null
): TaskExecutionResult {
  // No task graph = no orchestration = allow
  if (!taskGraph) {
    return { allowed: true };
  }

  // Only check Task tool calls
  if (input.tool.toLowerCase() !== "task") {
    return { allowed: true };
  }

  // Extract task ID from prompt/description
  const taskId = extractTaskIdFromArgs(input.args);

  // No task ID found = not a planned task = allow
  if (!taskId) {
    return { allowed: true };
  }

  // Find the task in the graph
  const task = taskGraph.tasks.find((t) => t.id === taskId);

  // Task not in graph = ad-hoc task = allow
  if (!task) {
    return { allowed: true, taskId };
  }

  const currentWave = taskGraph.current_wave;

  // Check 1: Wave order
  const waveResult = checkWaveOrder(task, currentWave);
  if (!waveResult.allowed) {
    throw new Error(waveResult.reason);
  }

  // Check 2: Dependencies
  const depResult = checkDependencies(task, taskGraph.tasks);
  if (!depResult.allowed) {
    throw new Error(depResult.reason);
  }

  // Check 3: Review gate (only for tasks in current wave when wave > 1)
  if (task.wave === currentWave && currentWave > 1) {
    const gateResult = checkReviewGate(currentWave - 1, taskGraph);
    if (!gateResult.allowed) {
      throw new Error(gateResult.reason);
    }
  }

  // All checks passed
  console.log(
    `[task-planner] Task execution validated: ${taskId} (wave ${task.wave})`
  );

  return {
    allowed: true,
    taskId,
  };
}

// ============================================================================
// Individual Check Functions
// ============================================================================

/**
 * Check 1: Wave order validation.
 *
 * Tasks can only be executed if they're in the current wave or earlier.
 */
export function checkWaveOrder(
  task: Task,
  currentWave: number
): TaskExecutionResult {
  if (task.wave > currentWave) {
    return {
      allowed: false,
      taskId: task.id,
      reason: ERRORS.WAVE_ORDER_VIOLATION(task.wave, currentWave),
      suggestion: `Complete all wave ${currentWave} tasks first.`,
    };
  }

  return { allowed: true, taskId: task.id };
}

/**
 * Check 2: Dependency validation.
 *
 * All tasks in depends_on must be completed or implemented.
 */
export function checkDependencies(
  task: Task,
  allTasks: Task[]
): TaskExecutionResult {
  if (!task.depends_on || task.depends_on.length === 0) {
    return { allowed: true, taskId: task.id };
  }

  const taskMap = new Map(allTasks.map((t) => [t.id, t]));
  const unmetDeps: string[] = [];

  for (const depId of task.depends_on) {
    const depTask = taskMap.get(depId);

    if (!depTask) {
      // Dependency not found in graph - treat as unmet
      unmetDeps.push(depId);
      continue;
    }

    if (!COMPLETED_TASK_STATUSES.includes(depTask.status)) {
      unmetDeps.push(`${depId} (status: ${depTask.status})`);
    }
  }

  if (unmetDeps.length > 0) {
    return {
      allowed: false,
      taskId: task.id,
      reason: ERRORS.TASK_DEPENDENCY_VIOLATION(task.id, unmetDeps),
      suggestion: "Complete the dependency tasks first.",
    };
  }

  return { allowed: true, taskId: task.id };
}

/**
 * Check 3: Review gate validation.
 *
 * Previous wave must have reviews_complete = true before starting current wave.
 */
export function checkReviewGate(
  prevWave: number,
  taskGraph: TaskGraph
): TaskExecutionResult {
  const gate: WaveGate | undefined = taskGraph.wave_gates[prevWave];

  // If no gate record exists, it hasn't been run yet
  if (!gate) {
    return {
      allowed: false,
      reason: ERRORS.REVIEW_GATE_NOT_PASSED(prevWave),
      suggestion: "Run /wave-gate",
    };
  }

  // Check if reviews are complete
  if (gate.reviews_complete !== true) {
    // Build list of reasons why gate is blocked
    const reasons: string[] = [];

    if (gate.blocked) {
      if (gate.tests_passed === false) {
        reasons.push("Integration tests failed");
      }

      // Count critical findings
      const criticalCount = taskGraph.tasks
        .filter((t) => t.wave === prevWave)
        .reduce((sum, t) => sum + (t.critical_findings?.length ?? 0), 0);

      if (criticalCount > 0) {
        reasons.push(`${criticalCount} critical review findings`);
      }
    }

    if (reasons.length > 0) {
      return {
        allowed: false,
        reason: ERRORS.REVIEW_GATE_BLOCKED(prevWave, reasons),
        suggestion: "Fix the issues and re-run /wave-gate",
      };
    }

    return {
      allowed: false,
      reason: ERRORS.REVIEW_GATE_NOT_PASSED(prevWave),
      suggestion: "Run /wave-gate",
    };
  }

  return { allowed: true };
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Check if a task is ready to execute.
 *
 * A task is ready if:
 * - It's in the current wave or earlier
 * - All its dependencies are completed
 * - Previous wave's review gate passed (if applicable)
 */
export function isTaskReady(task: Task, taskGraph: TaskGraph): boolean {
  const currentWave = taskGraph.current_wave;

  // Wave order check
  if (task.wave > currentWave) {
    return false;
  }

  // Dependency check
  const depResult = checkDependencies(task, taskGraph.tasks);
  if (!depResult.allowed) {
    return false;
  }

  // Review gate check (only for current wave tasks when wave > 1)
  if (task.wave === currentWave && currentWave > 1) {
    const gateResult = checkReviewGate(currentWave - 1, taskGraph);
    if (!gateResult.allowed) {
      return false;
    }
  }

  return true;
}

/**
 * Get all tasks that are ready to execute in the current wave.
 *
 * Returns tasks that pass all validation checks.
 */
export function getReadyTasks(taskGraph: TaskGraph): Task[] {
  return taskGraph.tasks.filter((task) => {
    // Only consider tasks in current wave that aren't already done
    if (task.wave !== taskGraph.current_wave) {
      return false;
    }

    if (COMPLETED_TASK_STATUSES.includes(task.status)) {
      return false;
    }

    if (task.status === "in_progress") {
      return false;
    }

    return isTaskReady(task, taskGraph);
  });
}

/**
 * Get remaining tasks in the current wave.
 *
 * Returns tasks that haven't been completed yet.
 */
export function getRemainingTasks(taskGraph: TaskGraph): Task[] {
  return taskGraph.tasks.filter(
    (task) =>
      task.wave === taskGraph.current_wave &&
      !COMPLETED_TASK_STATUSES.includes(task.status)
  );
}
