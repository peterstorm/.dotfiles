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
import type { TaskGraph, TaskCompletionContext, NewTestEvidence } from "../types.js";
import { StateManager } from "../utils/state-manager.js";
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
export declare function verifyNewTests(context: TaskCompletionContext, taskGraph: TaskGraph, stateManager: StateManager, diffContent?: string): Promise<NewTestEvidence | null>;
/**
 * Detect new test methods in diff content.
 *
 * Looks for added lines (starting with +) that match test patterns:
 * - Java: @Test, @Property, @ParameterizedTest
 * - TypeScript/JavaScript: it(, test(, describe(
 * - Python: def test_, class Test
 */
export declare function detectNewTests(diffContent: string): NewTestEvidence;
/**
 * Analyze files for new test methods.
 *
 * Alternative to diff-based detection - analyzes file content directly.
 * Useful when diff is not available.
 */
export declare function analyzeFilesForTests(files: Array<{
    path: string;
    content: string;
}>): NewTestEvidence;
/**
 * Check if a file path is a test file.
 */
export declare function isTestFile(path: string): boolean;
//# sourceMappingURL=verify-new-tests.d.ts.map