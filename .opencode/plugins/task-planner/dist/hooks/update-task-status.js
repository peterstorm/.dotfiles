/**
 * Update Task Status Hook
 *
 * Updates task status when an implementation agent completes.
 * Marks task as "implemented" (not "completed" - that happens after review gate).
 * Extracts test evidence from agent transcript for per-task test verification.
 *
 * This hook is called when an agent/task completes (SubagentStop equivalent).
 */
import { extractTaskId } from "../utils/task-id-extractor.js";
import { TEST_EVIDENCE_PATTERNS, TASK_REVIEW_AGENTS, CRASH_DETECTION_AGENTS, } from "../constants.js";
// ============================================================================
// Main Update Function
// ============================================================================
/**
 * Update task status when an agent completes.
 *
 * - Extracts task ID from transcript
 * - Extracts test evidence from output
 * - Marks task as "implemented"
 * - Updates executing_tasks list
 * - Checks if wave implementation is complete
 * - Handles crash detection for impl agents without task ID
 *
 * @param context - Task completion context with transcript and agent info
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @returns Updated task ID and status, or null if not a tracked task
 */
export async function updateTaskStatus(context, taskGraph, stateManager) {
    // Extract task ID from transcript
    const taskId = context.taskId ?? extractTaskId(context.transcript ?? "");
    // Skip review agents — they don't implement tasks
    if (isReviewAgent(context.agentType)) {
        console.log(`[task-planner] Skipping review agent for task ${taskId ?? "unknown"}`);
        return null;
    }
    // Crash detection: impl agent completed but no parseable task ID
    // Mark all executing tasks as failed (aggressive but recoverable via retry)
    if (!taskId) {
        if (isCrashDetectionAgent(context.agentType)) {
            return await handleCrashDetection(context.agentType, taskGraph, stateManager);
        }
        // Not a tracked task and not an impl agent
        return null;
    }
    // Find the task
    const task = taskGraph.tasks.find((t) => t.id === taskId);
    if (!task) {
        console.log(`[task-planner] Task ${taskId} not found in graph`);
        return null;
    }
    // Skip if already completed
    if (task.status === "completed") {
        console.log(`[task-planner] Task ${taskId} already completed`);
        return null;
    }
    // Allow re-extraction if implemented but missing test evidence
    if (task.status === "implemented" && task.tests_passed !== undefined) {
        console.log(`[task-planner] Task ${taskId} already implemented with test evidence`);
        return null;
    }
    // Extract test evidence from transcript
    const testEvidence = extractTestEvidence(context.transcript ?? "");
    // Update task state
    await stateManager.updateTask(taskId, {
        status: "implemented",
        tests_passed: testEvidence.passed,
        test_evidence: testEvidence.evidence,
        files_modified: context.filesModified,
    });
    // Remove from executing_tasks
    await stateManager.unmarkTaskExecuting(taskId);
    console.log(`[task-planner] Task ${taskId} implemented`);
    if (context.filesModified?.length) {
        console.log(`  Files modified: ${context.filesModified.length}`);
    }
    if (testEvidence.passed) {
        console.log(`  Tests passed: ${testEvidence.evidence}`);
    }
    else {
        console.log("  WARNING: No test pass evidence found in agent output");
    }
    // Check if wave is complete
    const updatedGraph = await stateManager.load();
    const waveComplete = await checkWaveComplete(taskGraph.current_wave, stateManager);
    // Get remaining tasks
    const remainingTasks = getRemainingTaskIds(updatedGraph ?? taskGraph, taskGraph.current_wave);
    if (remainingTasks.length > 0) {
        console.log(`Remaining in wave ${taskGraph.current_wave}: ${remainingTasks.join(", ")}`);
    }
    if (waveComplete) {
        // Mark wave impl_complete
        await stateManager.updateWaveGate(taskGraph.current_wave, {
            impl_complete: true,
        });
        console.log("");
        console.log("=========================================");
        console.log(`  Wave ${taskGraph.current_wave} implementation complete`);
        console.log("=========================================");
        console.log("");
        console.log("Run: /wave-gate");
        console.log("");
        console.log("(Tests + parallel code review + advance)");
    }
    return {
        taskId,
        testEvidence,
        waveComplete,
        remainingTasks,
    };
}
// ============================================================================
// Test Evidence Extraction
// ============================================================================
/**
 * Extract test evidence from agent transcript/output.
 *
 * Supports multiple test frameworks:
 * - Maven (Java): "BUILD SUCCESS" + "Tests run: X, Failures: 0, Errors: 0"
 * - Mocha (Node): "N passing" without "N failing"
 * - Vitest: "Tests X passed" or "Test Files X passed"
 * - pytest: "X passed" without "X failed"
 */
export function extractTestEvidence(transcript) {
    // Strip markdown bold markers for extraction
    const cleanTranscript = transcript.replace(/\*\*/g, "");
    // Try Maven/Java
    if (TEST_EVIDENCE_PATTERNS.maven.success.test(transcript)) {
        const match = cleanTranscript.match(TEST_EVIDENCE_PATTERNS.maven.results);
        if (match?.[0] && match[1]) {
            return {
                passed: true,
                framework: "maven",
                evidence: `maven: ${match[0]}`,
                testCount: parseInt(match[1], 10),
            };
        }
    }
    // Try Vitest (check before Mocha since patterns can overlap)
    const vitestPassed = cleanTranscript.match(TEST_EVIDENCE_PATTERNS.vitest.passed);
    const vitestFailed = cleanTranscript.match(TEST_EVIDENCE_PATTERNS.vitest.failed);
    if (vitestPassed?.[0] && vitestPassed[1] && !vitestFailed) {
        return {
            passed: true,
            framework: "vitest",
            evidence: `vitest: ${vitestPassed[0]}`,
            testCount: parseInt(vitestPassed[1], 10),
        };
    }
    // Try Mocha (Node) - use flexible pattern that matches "N ... passing"
    // First try exact match, then flexible match taking largest number
    const exactMocha = cleanTranscript.match(/(\d+)\s+passing/i);
    const flexibleMochaMatches = [...cleanTranscript.matchAll(/(\d+)(?:\s+\w+)*\s+passing/gi)];
    // Find best mocha match (largest count)
    let bestMochaMatch = exactMocha;
    if (!bestMochaMatch && flexibleMochaMatches.length > 0) {
        bestMochaMatch = flexibleMochaMatches[0];
        for (const m of flexibleMochaMatches) {
            if (parseInt(m[1] ?? "0", 10) > parseInt(bestMochaMatch[1] ?? "0", 10)) {
                bestMochaMatch = m;
            }
        }
    }
    const mochaFailing = cleanTranscript.match(TEST_EVIDENCE_PATTERNS.mocha.failing);
    if (bestMochaMatch?.[0] && bestMochaMatch[1]) {
        const failCount = mochaFailing?.[1] ? parseInt(mochaFailing[1], 10) : 0;
        if (failCount === 0) {
            return {
                passed: true,
                framework: "mocha",
                evidence: `node: ${bestMochaMatch[0]}`,
                testCount: parseInt(bestMochaMatch[1], 10),
            };
        }
    }
    // Try pytest
    const pytestPassed = cleanTranscript.match(TEST_EVIDENCE_PATTERNS.pytest.passed);
    const pytestFailed = cleanTranscript.match(TEST_EVIDENCE_PATTERNS.pytest.failed);
    if (pytestPassed?.[0] && pytestPassed[1]) {
        const failCount = pytestFailed?.[1] ? parseInt(pytestFailed[1], 10) : 0;
        if (failCount === 0) {
            return {
                passed: true,
                framework: "pytest",
                evidence: `pytest: ${pytestPassed[0]}`,
                testCount: parseInt(pytestPassed[1], 10),
            };
        }
    }
    // No evidence found
    return { passed: false };
}
// ============================================================================
// Helper Functions
// ============================================================================
/**
 * Check if an agent type is a review agent.
 */
export function isReviewAgent(agentType) {
    if (!agentType)
        return false;
    // Check explicit review agent types
    if (TASK_REVIEW_AGENTS.includes(agentType)) {
        return true;
    }
    // Check for review in agent name
    const lowerType = agentType.toLowerCase();
    return lowerType.includes("review") || lowerType.includes("reviewer");
}
/**
 * Check if all tasks in a wave are implemented or completed.
 */
export async function checkWaveComplete(wave, stateManager) {
    const tasks = await stateManager.getWaveTasks(wave);
    return tasks.every((t) => t.status === "implemented" || t.status === "completed");
}
/**
 * Get task IDs that are not yet implemented in a wave.
 */
export function getRemainingTaskIds(taskGraph, wave) {
    return taskGraph.tasks
        .filter((t) => t.wave === wave &&
        t.status !== "implemented" &&
        t.status !== "completed")
        .map((t) => t.id);
}
/**
 * Parse files modified from agent transcript.
 *
 * Looks for patterns like:
 * - "Wrote to file: path/to/file.ts"
 * - "Modified: path/to/file.ts"
 * - "Created: path/to/file.ts"
 */
export function parseFilesModified(transcript) {
    if (!transcript)
        return [];
    const patterns = [
        /(?:Wrote|Written|Modified|Created|Updated|Edited)(?:\s+to)?(?:\s+file)?:\s*['"]?([^\s'"]+)/gi,
        /file\.edited.*path['":\s]+([^\s'"]+)/gi,
    ];
    const files = new Set();
    for (const pattern of patterns) {
        const matches = transcript.matchAll(pattern);
        for (const match of matches) {
            if (match[1]) {
                files.add(match[1]);
            }
        }
    }
    return [...files];
}
// ============================================================================
// Crash Detection
// ============================================================================
/**
 * Check if an agent type triggers crash detection.
 *
 * Only implementation agents (not review/utility agents) trigger crash detection.
 * If an impl agent completes without a parseable task ID, it likely crashed or
 * was killed mid-execution.
 */
export function isCrashDetectionAgent(agentType) {
    if (!agentType)
        return false;
    return CRASH_DETECTION_AGENTS.includes(agentType);
}
/**
 * Handle crash detection for an impl agent that completed without a task ID.
 *
 * Marks all currently executing tasks as "failed" with:
 * - failure_reason: "agent_crash: no task ID in output"
 * - retry_count: incremented by 1
 *
 * This is aggressive but recoverable — tasks can be retried and the retry_count
 * helps identify persistent issues.
 *
 * @param agentType - The agent type that crashed
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @returns null (no task was successfully completed)
 */
async function handleCrashDetection(agentType, taskGraph, stateManager) {
    const executingTasks = taskGraph.executing_tasks ?? [];
    if (executingTasks.length === 0) {
        console.log(`[task-planner] Crash detection: impl agent (${agentType}) completed without task ID, but no executing tasks`);
        return null;
    }
    console.log("");
    console.log("=========================================");
    console.log("  CRASH DETECTED");
    console.log("=========================================");
    console.log(`  Agent type: ${agentType}`);
    console.log(`  Completed without parseable task ID in output`);
    console.log(`  Marking executing tasks as failed: ${executingTasks.join(", ")}`);
    console.log("");
    // Mark all executing tasks as failed with retry_count increment
    for (const taskId of executingTasks) {
        const task = taskGraph.tasks.find((t) => t.id === taskId);
        const currentRetryCount = task?.retry_count ?? 0;
        await stateManager.updateTask(taskId, {
            status: "failed",
            failure_reason: "agent_crash: no task ID in output",
            retry_count: currentRetryCount + 1,
        });
        // Remove from executing_tasks
        await stateManager.unmarkTaskExecuting(taskId);
    }
    console.log("  Tasks can be retried. Check agent output for issues.");
    console.log("");
    return null;
}
//# sourceMappingURL=update-task-status.js.map