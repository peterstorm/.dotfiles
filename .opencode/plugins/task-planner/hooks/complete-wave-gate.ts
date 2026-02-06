/**
 * Complete Wave Gate Hook
 *
 * Verifies all wave gate requirements are met before advancing to next wave:
 * 1. All tasks have test evidence (tests_passed = true)
 * 2. All tasks that require new tests have them (new_tests_written = true)
 * 3. All tasks have been reviewed (review_status = passed | blocked)
 * 4. No critical review findings
 * 5. Spec alignment verified (optional)
 *
 * This hook is called by the /wave-gate skill.
 */

import type { TaskGraph, Task, WaveGateResult } from "../types";
import { StateManager } from "../utils/state-manager";
import { ERRORS } from "../constants";

// ============================================================================
// Main Gate Verification
// ============================================================================

/**
 * Verify all wave gate requirements and optionally advance to next wave.
 *
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @param wave - Wave number to verify (defaults to current_wave)
 * @returns WaveGateResult with check details
 */
export async function completeWaveGate(
  taskGraph: TaskGraph,
  stateManager: StateManager,
  wave?: number
): Promise<WaveGateResult> {
  const targetWave = wave ?? taskGraph.current_wave;
  const waveTasks = taskGraph.tasks.filter((t) => t.wave === targetWave);

  console.log(`[task-planner] Completing wave ${targetWave} gate...`);
  console.log("");

  // Initialize result
  const result: WaveGateResult = {
    passed: false,
    wave: targetWave,
    checks: {
      testsPassed: false,
      newTestsVerified: false,
      reviewsComplete: false,
      noCriticalFindings: false,
    },
    failedTasks: {},
  };

  // Check 1: Test evidence
  const testResult = checkTestEvidence(waveTasks);
  result.checks.testsPassed = testResult.passed;
  if (!testResult.passed) {
    result.failedTasks!.missingTestEvidence = testResult.failedTasks;
    console.log(
      ERRORS.WAVE_GATE_TESTS_MISSING(targetWave, testResult.failedTasks)
    );
    return result;
  }
  console.log(
    `1. Test evidence verified (${waveTasks.length}/${waveTasks.length} tasks):`
  );
  for (const task of waveTasks) {
    console.log(`     ${task.id}: ${task.test_evidence ?? "evidence present"}`);
  }

  // Check 2: New tests written (if required)
  const newTestResult = checkNewTests(waveTasks);
  result.checks.newTestsVerified = newTestResult.passed;
  if (!newTestResult.passed) {
    result.failedTasks!.missingNewTests = newTestResult.failedTasks;
    console.log("");
    console.log(
      ERRORS.WAVE_GATE_NEW_TESTS_MISSING(targetWave, newTestResult.failedTasks)
    );
    return result;
  }
  console.log(`   New tests verified (${waveTasks.length}/${waveTasks.length} tasks):`);
  for (const task of waveTasks) {
    const evidence =
      task.new_tests_required === false
        ? "not required"
        : task.new_test_evidence ?? "new tests present";
    console.log(`     ${task.id}: ${evidence}`);
  }

  // Mark tests_passed in wave gate
  await stateManager.updateWaveGate(targetWave, { tests_passed: true });

  // Check 3: Reviews complete
  const reviewResult = checkReviews(waveTasks);
  result.checks.reviewsComplete = reviewResult.passed;
  if (!reviewResult.passed) {
    result.failedTasks!.unreviewed = reviewResult.failedTasks;
    console.log("");
    console.log(
      ERRORS.WAVE_GATE_REVIEWS_MISSING(targetWave, reviewResult.failedTasks)
    );
    return result;
  }
  console.log(`2. Reviews verified (${waveTasks.length}/${waveTasks.length} tasks):`);
  for (const task of waveTasks) {
    console.log(`     ${task.id}: ${task.review_status}`);
  }

  // Check 4: Spec alignment (optional)
  if (taskGraph.spec_check) {
    const specResult = checkSpecAlignment(taskGraph, targetWave);
    result.checks.specAligned = specResult.passed;
    if (!specResult.passed) {
      console.log("");
      console.log(
        `FAILED: Spec alignment has ${taskGraph.spec_check.critical_count} critical findings.`
      );
      for (const finding of taskGraph.spec_check.critical_findings) {
        console.log(`  - ${finding}`);
      }
      console.log("");
      console.log("Fix spec drift and re-run /wave-gate.");
      return result;
    }
    console.log(
      `3. Spec alignment verified (verdict: ${taskGraph.spec_check.verdict}).`
    );
  } else {
    console.log(
      "3. Spec alignment: skipped (no spec-check data - run /wave-gate to spawn)."
    );
    result.checks.specAligned = true; // Not required
  }

  // Check 5: No critical review findings
  const criticalResult = checkCriticalFindings(waveTasks);
  result.checks.noCriticalFindings = criticalResult.passed;
  if (!criticalResult.passed) {
    result.failedTasks!.criticalFindings = criticalResult.failedTasks;
    console.log("");
    console.log(
      ERRORS.WAVE_GATE_CRITICAL_FINDINGS(
        targetWave,
        criticalResult.totalFindings
      )
    );
    for (const task of waveTasks) {
      if (task.critical_findings && task.critical_findings.length > 0) {
        console.log(`  ${task.id}: ${task.critical_findings.join(", ")}`);
      }
    }
    return result;
  }
  console.log("4. No critical code review findings.");

  // All checks passed!
  result.passed = true;
  console.log("");
  console.log("All checks passed. Advancing...");

  // Mark all wave tasks as "completed" and review_status = "passed"
  for (const task of waveTasks) {
    await stateManager.updateTask(task.id, {
      status: "completed",
      review_status: "passed",
    });
  }

  // Update wave gate
  await stateManager.updateWaveGate(targetWave, {
    reviews_complete: true,
    blocked: false,
  });

  console.log(`Marked wave ${targetWave} tasks completed.`);

  // Advance to next wave if there is one
  const maxWave = Math.max(...taskGraph.tasks.map((t) => t.wave));
  const nextWave = targetWave + 1;

  if (nextWave <= maxWave) {
    // Initialize next wave gate
    await stateManager.updateWaveGate(nextWave, {
      impl_complete: false,
      tests_passed: undefined,
      reviews_complete: false,
      blocked: false,
    });

    // Advance current wave
    const updatedGraph = await stateManager.load();
    if (updatedGraph) {
      updatedGraph.current_wave = nextWave;
      await stateManager.save(updatedGraph);
    }

    console.log(`Advanced to wave ${nextWave}.`);
    console.log("");
    console.log(`Ready to execute wave ${nextWave} tasks.`);
  } else {
    console.log("");
    console.log("=== All waves complete! ===");
    console.log("Run /task-planner --complete to finalize.");
  }

  return result;
}

// ============================================================================
// Individual Check Functions
// ============================================================================

/**
 * Check 1: All tasks have test evidence.
 */
export function checkTestEvidence(tasks: Task[]): {
  passed: boolean;
  failedTasks: string[];
} {
  const failed = tasks
    .filter((t) => t.tests_passed !== true)
    .map((t) => t.id);

  return {
    passed: failed.length === 0,
    failedTasks: failed,
  };
}

/**
 * Check 2: All tasks that require new tests have them.
 *
 * Task passes if:
 * - new_tests_required === false, OR
 * - new_tests_written === true
 */
export function checkNewTests(tasks: Task[]): {
  passed: boolean;
  failedTasks: string[];
} {
  const failed = tasks
    .filter(
      (t) =>
        t.new_tests_required !== false && t.new_tests_written !== true
    )
    .map((t) => t.id);

  return {
    passed: failed.length === 0,
    failedTasks: failed,
  };
}

/**
 * Check 3: All tasks have been reviewed.
 *
 * Review status must be "passed" or "blocked" (not "pending" or undefined).
 */
export function checkReviews(tasks: Task[]): {
  passed: boolean;
  failedTasks: string[];
} {
  const failed = tasks
    .filter(
      (t) => t.review_status !== "passed" && t.review_status !== "blocked"
    )
    .map((t) => t.id);

  return {
    passed: failed.length === 0,
    failedTasks: failed,
  };
}

/**
 * Check 4: Spec alignment is verified.
 */
export function checkSpecAlignment(
  taskGraph: TaskGraph,
  wave: number
): { passed: boolean } {
  if (!taskGraph.spec_check) {
    return { passed: true }; // No spec check = skip
  }

  // Warn if spec check was for a different wave
  if (taskGraph.spec_check.wave !== wave) {
    console.log("");
    console.log(
      `WARNING: Spec-check was run for wave ${taskGraph.spec_check.wave}, not current wave ${wave}.`
    );
    console.log("Re-run /wave-gate to spawn spec-check for this wave.");
  }

  // Check for critical findings
  if (taskGraph.spec_check.critical_count > 0) {
    return { passed: false };
  }

  return { passed: true };
}

/**
 * Check 5: No critical review findings in any task.
 */
export function checkCriticalFindings(tasks: Task[]): {
  passed: boolean;
  failedTasks: string[];
  totalFindings: number;
} {
  let totalFindings = 0;
  const failed: string[] = [];

  for (const task of tasks) {
    const count = task.critical_findings?.length ?? 0;
    if (count > 0) {
      totalFindings += count;
      failed.push(task.id);
    }
  }

  return {
    passed: totalFindings === 0,
    failedTasks: failed,
    totalFindings,
  };
}

// ============================================================================
// Wave Status Helpers
// ============================================================================

/**
 * Check if a wave's implementation is complete.
 *
 * All tasks must be "implemented" or "completed".
 */
export function isWaveImplementationComplete(
  taskGraph: TaskGraph,
  wave: number
): boolean {
  const waveTasks = taskGraph.tasks.filter((t) => t.wave === wave);

  return waveTasks.every(
    (t) => t.status === "implemented" || t.status === "completed"
  );
}

/**
 * Get wave gate status summary.
 */
export function getWaveGateStatus(
  taskGraph: TaskGraph,
  wave: number
): {
  implComplete: boolean;
  testsPassed: boolean | null;
  reviewsComplete: boolean;
  blocked: boolean;
} {
  const gate = taskGraph.wave_gates[wave];

  if (!gate) {
    return {
      implComplete: isWaveImplementationComplete(taskGraph, wave),
      testsPassed: null,
      reviewsComplete: false,
      blocked: false,
    };
  }

  return {
    implComplete: gate.impl_complete ?? false,
    testsPassed: gate.tests_passed ?? null,
    reviewsComplete: gate.reviews_complete ?? false,
    blocked: gate.blocked ?? false,
  };
}

/**
 * Get maximum wave number in the task graph.
 */
export function getMaxWave(taskGraph: TaskGraph): number {
  if (taskGraph.tasks.length === 0) return 0;
  return Math.max(...taskGraph.tasks.map((t) => t.wave));
}

/**
 * Check if all waves are complete.
 */
export function areAllWavesComplete(taskGraph: TaskGraph): boolean {
  const maxWave = getMaxWave(taskGraph);

  for (let wave = 1; wave <= maxWave; wave++) {
    const status = getWaveGateStatus(taskGraph, wave);
    if (!status.reviewsComplete) {
      return false;
    }
  }

  return true;
}
