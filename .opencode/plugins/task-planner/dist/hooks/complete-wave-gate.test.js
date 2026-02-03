/**
 * Tests for complete-wave-gate hook
 */
import { describe, it, expect } from "vitest";
import { checkTestEvidence, checkNewTests, checkReviews, checkCriticalFindings, checkSpecAlignment, isWaveImplementationComplete, getWaveGateStatus, getMaxWave, areAllWavesComplete, } from "./complete-wave-gate.js";
// ============================================================================
// Test Fixtures
// ============================================================================
function createTask(overrides = {}) {
    return {
        id: "T1",
        description: "Test task",
        wave: 1,
        status: "pending",
        agent: "code-implementer-agent",
        depends_on: [],
        ...overrides,
    };
}
function createTaskGraph(overrides = {}) {
    return {
        title: "Test Task Graph",
        spec_file: ".opencode/specs/test.md",
        plan_file: ".opencode/plans/test.md",
        current_phase: "execute",
        phase_artifacts: {},
        skipped_phases: [],
        current_wave: 1,
        tasks: [],
        executing_tasks: [],
        wave_gates: {},
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        ...overrides,
    };
}
// ============================================================================
// checkTestEvidence Tests
// ============================================================================
describe("checkTestEvidence", () => {
    it("passes when all tasks have tests_passed = true", () => {
        const tasks = [
            createTask({ id: "T1", tests_passed: true }),
            createTask({ id: "T2", tests_passed: true }),
            createTask({ id: "T3", tests_passed: true }),
        ];
        const result = checkTestEvidence(tasks);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
    it("fails when any task has tests_passed = false", () => {
        const tasks = [
            createTask({ id: "T1", tests_passed: true }),
            createTask({ id: "T2", tests_passed: false }),
            createTask({ id: "T3", tests_passed: true }),
        ];
        const result = checkTestEvidence(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T2"]);
    });
    it("fails when any task has tests_passed = undefined", () => {
        const tasks = [
            createTask({ id: "T1", tests_passed: true }),
            createTask({ id: "T2" }), // tests_passed is undefined
        ];
        const result = checkTestEvidence(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T2"]);
    });
    it("reports all failed tasks", () => {
        const tasks = [
            createTask({ id: "T1" }),
            createTask({ id: "T2", tests_passed: false }),
            createTask({ id: "T3" }),
        ];
        const result = checkTestEvidence(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T1", "T2", "T3"]);
    });
    it("passes for empty task list", () => {
        const result = checkTestEvidence([]);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
});
// ============================================================================
// checkNewTests Tests
// ============================================================================
describe("checkNewTests", () => {
    it("passes when all tasks with new_tests_required have new_tests_written", () => {
        const tasks = [
            createTask({ id: "T1", new_tests_required: true, new_tests_written: true }),
            createTask({ id: "T2", new_tests_required: true, new_tests_written: true }),
        ];
        const result = checkNewTests(tasks);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
    it("passes when new_tests_required is false", () => {
        const tasks = [
            createTask({ id: "T1", new_tests_required: false }),
            createTask({ id: "T2", new_tests_required: false }),
        ];
        const result = checkNewTests(tasks);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
    it("fails when new_tests_required is true but new_tests_written is false", () => {
        const tasks = [
            createTask({ id: "T1", new_tests_required: true, new_tests_written: false }),
        ];
        const result = checkNewTests(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T1"]);
    });
    it("fails when new_tests_required is true but new_tests_written is undefined", () => {
        const tasks = [
            createTask({ id: "T1", new_tests_required: true }),
        ];
        const result = checkNewTests(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T1"]);
    });
    it("fails when new_tests_required is undefined (defaults to true)", () => {
        const tasks = [
            createTask({ id: "T1" }), // new_tests_required undefined means it defaults to required
        ];
        const result = checkNewTests(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T1"]);
    });
    it("mixed: passes only tasks that satisfy requirement", () => {
        const tasks = [
            createTask({ id: "T1", new_tests_required: true, new_tests_written: true }),
            createTask({ id: "T2", new_tests_required: false }),
            createTask({ id: "T3", new_tests_required: true, new_tests_written: false }),
            createTask({ id: "T4" }), // Defaults to required, not written
        ];
        const result = checkNewTests(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T3", "T4"]);
    });
    it("passes for empty task list", () => {
        const result = checkNewTests([]);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
});
// ============================================================================
// checkReviews Tests
// ============================================================================
describe("checkReviews", () => {
    it("passes when all tasks have review_status = passed", () => {
        const tasks = [
            createTask({ id: "T1", review_status: "passed" }),
            createTask({ id: "T2", review_status: "passed" }),
        ];
        const result = checkReviews(tasks);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
    it("passes when review_status is blocked (still reviewed)", () => {
        const tasks = [
            createTask({ id: "T1", review_status: "passed" }),
            createTask({ id: "T2", review_status: "blocked" }),
        ];
        const result = checkReviews(tasks);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
    it("fails when review_status is pending", () => {
        const tasks = [
            createTask({ id: "T1", review_status: "passed" }),
            createTask({ id: "T2", review_status: "pending" }),
        ];
        const result = checkReviews(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T2"]);
    });
    it("fails when review_status is undefined", () => {
        const tasks = [
            createTask({ id: "T1", review_status: "passed" }),
            createTask({ id: "T2" }), // No review_status
        ];
        const result = checkReviews(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T2"]);
    });
    it("fails when review_status is evidence_capture_failed", () => {
        const tasks = [
            createTask({ id: "T1", review_status: "evidence_capture_failed" }),
        ];
        const result = checkReviews(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T1"]);
    });
    it("passes for empty task list", () => {
        const result = checkReviews([]);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
    });
});
// ============================================================================
// checkCriticalFindings Tests
// ============================================================================
describe("checkCriticalFindings", () => {
    it("passes when no tasks have critical findings", () => {
        const tasks = [
            createTask({ id: "T1", critical_findings: [] }),
            createTask({ id: "T2", critical_findings: [] }),
        ];
        const result = checkCriticalFindings(tasks);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
        expect(result.totalFindings).toBe(0);
    });
    it("passes when critical_findings is undefined", () => {
        const tasks = [
            createTask({ id: "T1" }),
            createTask({ id: "T2" }),
        ];
        const result = checkCriticalFindings(tasks);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
        expect(result.totalFindings).toBe(0);
    });
    it("fails when any task has critical findings", () => {
        const tasks = [
            createTask({ id: "T1", critical_findings: ["Memory leak detected"] }),
            createTask({ id: "T2", critical_findings: [] }),
        ];
        const result = checkCriticalFindings(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T1"]);
        expect(result.totalFindings).toBe(1);
    });
    it("counts total findings across all tasks", () => {
        const tasks = [
            createTask({ id: "T1", critical_findings: ["Issue 1", "Issue 2"] }),
            createTask({ id: "T2", critical_findings: ["Issue 3"] }),
            createTask({ id: "T3", critical_findings: [] }),
        ];
        const result = checkCriticalFindings(tasks);
        expect(result.passed).toBe(false);
        expect(result.failedTasks).toEqual(["T1", "T2"]);
        expect(result.totalFindings).toBe(3);
    });
    it("passes for empty task list", () => {
        const result = checkCriticalFindings([]);
        expect(result.passed).toBe(true);
        expect(result.failedTasks).toEqual([]);
        expect(result.totalFindings).toBe(0);
    });
});
// ============================================================================
// checkSpecAlignment Tests
// ============================================================================
describe("checkSpecAlignment", () => {
    it("passes when no spec_check exists", () => {
        const taskGraph = createTaskGraph();
        const result = checkSpecAlignment(taskGraph, 1);
        expect(result.passed).toBe(true);
    });
    it("passes when spec_check has no critical findings", () => {
        const taskGraph = createTaskGraph({
            spec_check: {
                wave: 1,
                run_at: new Date().toISOString(),
                critical_count: 0,
                high_count: 1,
                critical_findings: [],
                high_findings: ["Minor alignment issue"],
                medium_findings: [],
                verdict: "PASSED",
            },
        });
        const result = checkSpecAlignment(taskGraph, 1);
        expect(result.passed).toBe(true);
    });
    it("fails when spec_check has critical findings", () => {
        const taskGraph = createTaskGraph({
            spec_check: {
                wave: 1,
                run_at: new Date().toISOString(),
                critical_count: 2,
                high_count: 0,
                critical_findings: ["Missing feature X", "Wrong behavior for Y"],
                high_findings: [],
                medium_findings: [],
                verdict: "BLOCKED",
            },
        });
        const result = checkSpecAlignment(taskGraph, 1);
        expect(result.passed).toBe(false);
    });
    it("passes even if spec_check is for different wave (just warns)", () => {
        const taskGraph = createTaskGraph({
            spec_check: {
                wave: 1,
                run_at: new Date().toISOString(),
                critical_count: 0,
                high_count: 0,
                critical_findings: [],
                high_findings: [],
                medium_findings: [],
                verdict: "PASSED",
            },
        });
        // Checking wave 2 but spec_check is for wave 1
        const result = checkSpecAlignment(taskGraph, 2);
        expect(result.passed).toBe(true);
    });
});
// ============================================================================
// isWaveImplementationComplete Tests
// ============================================================================
describe("isWaveImplementationComplete", () => {
    it("returns true when all tasks in wave are implemented or completed", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1, status: "implemented" }),
                createTask({ id: "T2", wave: 1, status: "completed" }),
                createTask({ id: "T3", wave: 2, status: "pending" }),
            ],
        });
        expect(isWaveImplementationComplete(taskGraph, 1)).toBe(true);
    });
    it("returns false when any task in wave is pending", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1, status: "implemented" }),
                createTask({ id: "T2", wave: 1, status: "pending" }),
            ],
        });
        expect(isWaveImplementationComplete(taskGraph, 1)).toBe(false);
    });
    it("returns false when any task in wave is in_progress", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1, status: "completed" }),
                createTask({ id: "T2", wave: 1, status: "in_progress" }),
            ],
        });
        expect(isWaveImplementationComplete(taskGraph, 1)).toBe(false);
    });
    it("returns true for wave with no tasks", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1, status: "pending" }),
            ],
        });
        expect(isWaveImplementationComplete(taskGraph, 2)).toBe(true);
    });
    it("ignores tasks from other waves", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1, status: "completed" }),
                createTask({ id: "T2", wave: 2, status: "pending" }),
                createTask({ id: "T3", wave: 3, status: "pending" }),
            ],
        });
        expect(isWaveImplementationComplete(taskGraph, 1)).toBe(true);
        expect(isWaveImplementationComplete(taskGraph, 2)).toBe(false);
    });
});
// ============================================================================
// getWaveGateStatus Tests
// ============================================================================
describe("getWaveGateStatus", () => {
    it("returns default values when no gate exists", () => {
        const taskGraph = createTaskGraph({
            tasks: [createTask({ id: "T1", wave: 1, status: "pending" })],
        });
        const status = getWaveGateStatus(taskGraph, 1);
        expect(status.implComplete).toBe(false);
        expect(status.testsPassed).toBeNull();
        expect(status.reviewsComplete).toBe(false);
        expect(status.blocked).toBe(false);
    });
    it("returns gate values when gate exists", () => {
        const taskGraph = createTaskGraph({
            wave_gates: {
                1: {
                    impl_complete: true,
                    tests_passed: true,
                    reviews_complete: true,
                    blocked: false,
                },
            },
        });
        const status = getWaveGateStatus(taskGraph, 1);
        expect(status.implComplete).toBe(true);
        expect(status.testsPassed).toBe(true);
        expect(status.reviewsComplete).toBe(true);
        expect(status.blocked).toBe(false);
    });
    it("returns blocked status correctly", () => {
        const taskGraph = createTaskGraph({
            wave_gates: {
                1: {
                    impl_complete: true,
                    tests_passed: false,
                    reviews_complete: false,
                    blocked: true,
                },
            },
        });
        const status = getWaveGateStatus(taskGraph, 1);
        expect(status.blocked).toBe(true);
        expect(status.testsPassed).toBe(false);
    });
    it("computes implComplete from tasks if not in gate", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1, status: "implemented" }),
                createTask({ id: "T2", wave: 1, status: "completed" }),
            ],
            wave_gates: {}, // Empty gates
        });
        const status = getWaveGateStatus(taskGraph, 1);
        expect(status.implComplete).toBe(true);
    });
});
// ============================================================================
// getMaxWave Tests
// ============================================================================
describe("getMaxWave", () => {
    it("returns 0 for empty task list", () => {
        const taskGraph = createTaskGraph({ tasks: [] });
        expect(getMaxWave(taskGraph)).toBe(0);
    });
    it("returns maximum wave number", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1 }),
                createTask({ id: "T2", wave: 3 }),
                createTask({ id: "T3", wave: 2 }),
            ],
        });
        expect(getMaxWave(taskGraph)).toBe(3);
    });
    it("handles single task", () => {
        const taskGraph = createTaskGraph({
            tasks: [createTask({ id: "T1", wave: 5 })],
        });
        expect(getMaxWave(taskGraph)).toBe(5);
    });
});
// ============================================================================
// areAllWavesComplete Tests
// ============================================================================
describe("areAllWavesComplete", () => {
    it("returns true when all waves have reviews_complete", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1 }),
                createTask({ id: "T2", wave: 2 }),
                createTask({ id: "T3", wave: 3 }),
            ],
            wave_gates: {
                1: { reviews_complete: true },
                2: { reviews_complete: true },
                3: { reviews_complete: true },
            },
        });
        expect(areAllWavesComplete(taskGraph)).toBe(true);
    });
    it("returns false when any wave is not complete", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1 }),
                createTask({ id: "T2", wave: 2 }),
            ],
            wave_gates: {
                1: { reviews_complete: true },
                2: { reviews_complete: false },
            },
        });
        expect(areAllWavesComplete(taskGraph)).toBe(false);
    });
    it("returns false when wave gate is missing", () => {
        const taskGraph = createTaskGraph({
            tasks: [
                createTask({ id: "T1", wave: 1 }),
                createTask({ id: "T2", wave: 2 }),
            ],
            wave_gates: {
                1: { reviews_complete: true },
                // Wave 2 gate is missing
            },
        });
        expect(areAllWavesComplete(taskGraph)).toBe(false);
    });
    it("returns true for empty task list", () => {
        const taskGraph = createTaskGraph({ tasks: [] });
        expect(areAllWavesComplete(taskGraph)).toBe(true);
    });
});
//# sourceMappingURL=complete-wave-gate.test.js.map