/**
 * Verify New Tests Hook
 *
 * Verifies that implementation agents wrote NEW tests (not just reran existing).
 * Checks git diff for new test method patterns (@Test, it(, test(, describe().
 *
 * Only runs for implementation agents (skips reviewers).
 * Sets new_tests_written + new_test_evidence in task state.
 *
 * This hook is called when an agent completes (SubagentStop equivalent).
 */
import { extractTaskId } from "../utils/task-id-extractor.js";
import { NEW_TEST_PATTERNS, TASK_REVIEW_AGENTS } from "../constants.js";
// ============================================================================
// Main Verification Function
// ============================================================================
/**
 * Verify that new tests were written for a task.
 *
 * Analyzes git diff output or file content to detect new test methods.
 * Updates task state with new_tests_written and new_test_evidence.
 *
 * @param context - Task completion context with transcript and files
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @param diffContent - Git diff output to analyze (optional)
 * @returns NewTestEvidence with detection results, or null if not applicable
 */
export async function verifyNewTests(context, taskGraph, stateManager, diffContent) {
    // Extract task ID
    const taskId = context.taskId ?? extractTaskId(context.transcript ?? "");
    if (!taskId) {
        return null;
    }
    // Find the task
    const task = taskGraph.tasks.find((t) => t.id === taskId);
    if (!task) {
        console.log(`[task-planner] Task ${taskId} not found for new-test verification`);
        return null;
    }
    // Skip review agents
    if (isReviewAgent(context.agentType)) {
        return null;
    }
    // Skip if already verified as true
    if (task.new_tests_written === true) {
        console.log(`[task-planner] Task ${taskId} already has new-test evidence`);
        return null;
    }
    // Check if new tests are required
    if (task.new_tests_required === false) {
        // Mark as skipped
        await stateManager.updateTask(taskId, {
            new_tests_written: false,
            new_test_evidence: "new_tests_required=false (skipped)",
        });
        console.log(`[task-planner] Task ${taskId}: new_tests_required=false, skipping verification`);
        return {
            written: false,
            count: 0,
            evidence: "new_tests_required=false (skipped)",
        };
    }
    // Analyze diff for new test methods
    const evidence = detectNewTests(diffContent ?? "");
    // Update task state
    await stateManager.updateTask(taskId, {
        new_tests_written: evidence.written,
        new_test_evidence: evidence.evidence ?? "",
    });
    // Log results
    console.log(`[task-planner] Task ${taskId} new-test verification:`);
    if (context.filesModified?.length) {
        console.log(`  Scope: ${context.filesModified.length} files from transcript`);
    }
    else {
        console.log("  Scope: fallback (diff-based)");
    }
    if (evidence.written) {
        console.log(`  NEW TESTS: ${evidence.evidence}`);
    }
    else {
        console.log("  WARNING: No new test methods detected in diff");
        console.log("  Agent may have only rerun existing tests without writing new ones");
    }
    return evidence;
}
// ============================================================================
// New Test Detection
// ============================================================================
/**
 * Detect new test methods in diff content.
 *
 * Looks for added lines (starting with +) that match test patterns:
 * - Java: @Test, @Property, @ParameterizedTest
 * - TypeScript/JavaScript: it(, test(, describe(
 * - Python: def test_, class Test
 */
export function detectNewTests(diffContent) {
    if (!diffContent) {
        return { written: false, count: 0 };
    }
    let totalCount = 0;
    const details = [];
    // Java tests
    const javaCount = countMatches(diffContent, NEW_TEST_PATTERNS.java);
    if (javaCount > 0) {
        totalCount += javaCount;
        details.push(`java: ${javaCount} new @Test/@Property methods`);
    }
    // TypeScript/JavaScript tests
    const tsCount = countMatches(diffContent, NEW_TEST_PATTERNS.typescript);
    if (tsCount > 0) {
        totalCount += tsCount;
        details.push(`ts/js: ${tsCount} new it/test/describe blocks`);
    }
    // Python tests
    const pyCount = countMatches(diffContent, NEW_TEST_PATTERNS.python);
    if (pyCount > 0) {
        totalCount += pyCount;
        details.push(`python: ${pyCount} new test functions/classes`);
    }
    if (totalCount > 0) {
        return {
            written: true,
            count: totalCount,
            evidence: `${totalCount} new test methods (${details.join("; ")})`,
        };
    }
    return { written: false, count: 0 };
}
/**
 * Count matches of a pattern in diff content.
 *
 * The pattern should match lines starting with + (added lines).
 */
function countMatches(content, pattern) {
    // Split into lines and count matches
    const lines = content.split("\n");
    let count = 0;
    for (const line of lines) {
        // Only check added lines (starting with +, but not +++)
        if (line.startsWith("+") && !line.startsWith("+++")) {
            if (pattern.test(line)) {
                count++;
            }
        }
    }
    return count;
}
// ============================================================================
// Helper Functions
// ============================================================================
/**
 * Check if an agent type is a review agent.
 */
function isReviewAgent(agentType) {
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
 * Analyze files for new test methods.
 *
 * Alternative to diff-based detection - analyzes file content directly.
 * Useful when diff is not available.
 */
export function analyzeFilesForTests(files) {
    let totalCount = 0;
    for (const file of files) {
        // Check if it's a test file
        if (!isTestFile(file.path)) {
            continue;
        }
        // Count test methods in file (not diff, so all are "new" in context of this file)
        const javaCount = (file.content.match(/@(Test|Property|ParameterizedTest)\b/g) ?? []).length;
        const tsCount = (file.content.match(/\b(it|test|describe)\(/g) ?? []).length;
        const pyCount = (file.content.match(/(def test_|class Test)/g) ?? []).length;
        const fileCount = javaCount + tsCount + pyCount;
        if (fileCount > 0) {
            totalCount += fileCount;
        }
    }
    if (totalCount > 0) {
        return {
            written: true,
            count: totalCount,
            evidence: `${totalCount} test methods found in modified test files`,
        };
    }
    return { written: false, count: 0 };
}
/**
 * Check if a file path is a test file.
 */
export function isTestFile(path) {
    const testPatterns = [
        /\.test\.[jt]sx?$/,
        /\.spec\.[jt]sx?$/,
        /Test\.java$/,
        /IT\.java$/,
        /Tests?\.kt$/,
        /__tests__\//,
        /src\/test\//,
        /test_.*\.py$/,
        /_test\.py$/,
    ];
    return testPatterns.some((pattern) => pattern.test(path));
}
//# sourceMappingURL=verify-new-tests.js.map