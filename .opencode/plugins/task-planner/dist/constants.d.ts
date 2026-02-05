/**
 * Task Planner Plugin - Constants
 *
 * Centralized configuration values for the task-planner plugin.
 */
import type { Phase, AgentType } from "./types.js";
/** State directory relative to project root */
export declare const STATE_DIR = ".opencode/state";
/** Active task graph filename */
export declare const TASK_GRAPH_FILENAME = "active_task_graph.json";
/** Lock file for state operations */
export declare const LOCK_FILENAME = ".task_graph.lock";
/** Specs directory relative to project root */
export declare const SPECS_DIR = ".opencode/specs";
/** Plans directory relative to project root */
export declare const PLANS_DIR = ".opencode/plans";
/** Ordered list of phases in the workflow */
export declare const PHASE_ORDER: readonly Phase[];
/** Phases that can be skipped (non-mandatory) */
export declare const SKIPPABLE_PHASES: readonly Phase[];
/** Phases that produce artifacts */
export declare const ARTIFACT_PHASES: readonly Phase[];
/** Map skill names to their workflow phases */
export declare const SKILL_TO_PHASE: Record<string, Phase>;
/** Skills exempt from phase validation (utility skills) */
export declare const PHASE_EXEMPT_SKILLS: readonly string[];
/** Valid phase transitions */
export declare const VALID_TRANSITIONS: Record<Phase, readonly Phase[]>;
/** Patterns to detect phase completion in message content */
export declare const PHASE_COMPLETION_PATTERNS: Record<Phase, RegExp>;
/** Pattern to extract artifact file paths from messages */
export declare const ARTIFACT_PATH_PATTERN: RegExp;
/** Pattern to count clarification markers in spec files */
export declare const CLARIFICATION_MARKER_PATTERN: RegExp;
/** Threshold for auto-skipping clarify phase */
export declare const CLARIFY_MARKER_THRESHOLD = 3;
/** Allowed artifact path prefixes (for security) */
export declare const ALLOWED_ARTIFACT_PATHS: readonly RegExp[];
/** Debounce time for session.idle phase advancement checks (ms) */
export declare const PHASE_ADVANCEMENT_DEBOUNCE_MS = 500;
/** Tools blocked during orchestration (direct edits not allowed) */
export declare const BLOCKED_TOOLS: readonly string[];
/** File patterns for state files that should be protected from Bash writes */
export declare const PROTECTED_STATE_PATTERNS: readonly RegExp[];
/** Bash commands that write to files */
export declare const BASH_WRITE_PATTERNS: readonly RegExp[];
/** Agent types that perform implementation work */
export declare const IMPLEMENTATION_AGENTS: readonly AgentType[];
/** Agent types that perform review/validation work */
export declare const REVIEW_AGENTS: readonly AgentType[];
/** Pattern to extract task ID from text (e.g., "T1", "T2", "Task 3") */
export declare const TASK_ID_PATTERN: RegExp;
/** Pattern to extract multiple task IDs */
export declare const TASK_ID_GLOBAL_PATTERN: RegExp;
/** Pattern to identify CRITICAL findings in review output */
export declare const CRITICAL_FINDING_PATTERN: RegExp;
/** Pattern to identify ADVISORY findings in review output */
export declare const ADVISORY_FINDING_PATTERN: RegExp;
/** Pattern to identify spec-check findings */
export declare const SPEC_CHECK_FINDING_PATTERN: RegExp;
/** File patterns that indicate test files */
export declare const TEST_FILE_PATTERNS: readonly RegExp[];
/** Patterns that indicate new test methods in diff output */
export declare const NEW_TEST_METHOD_PATTERNS: readonly RegExp[];
/** Lock acquisition timeout in milliseconds */
export declare const LOCK_TIMEOUT_MS = 5000;
/** Lock retry interval in milliseconds */
export declare const LOCK_RETRY_INTERVAL_MS = 100;
/** Maximum lock acquisition attempts */
export declare const MAX_LOCK_ATTEMPTS = 50;
/** Stale agent tracking file age in minutes */
export declare const STALE_AGENT_MINUTES = 60;
/**
 * Test evidence patterns for different test frameworks.
 *
 * Used to extract test results from agent output/transcripts.
 * Each pattern captures the evidence string for logging.
 */
export declare const TEST_EVIDENCE_PATTERNS: {
    /**
     * Maven/Java: "Tests run: X, Failures: 0, Errors: 0"
     * Also handles markdown bold: "Tests run: **128**, Failures: **0**, Errors: **0**"
     */
    readonly maven: {
        readonly success: RegExp;
        readonly results: RegExp;
    };
    /**
     * Node/Mocha: "N passing" without "N failing"
     */
    readonly mocha: {
        readonly passing: RegExp;
        readonly failing: RegExp;
    };
    /**
     * Vitest: "Tests X passed" or "Test Files X passed"
     */
    readonly vitest: {
        readonly passed: RegExp;
        readonly failed: RegExp;
    };
    /**
     * pytest: "X passed" without "X failed"
     */
    readonly pytest: {
        readonly passed: RegExp;
        readonly failed: RegExp;
    };
    /**
     * JUnit: XML-style output or "N tests completed"
     */
    readonly junit: {
        readonly success: RegExp;
    };
};
/**
 * Patterns to detect new test methods in git diff output.
 *
 * Each pattern matches added lines (starting with +) that indicate
 * a new test method was created.
 */
export declare const NEW_TEST_PATTERNS: {
    /** Java: @Test, @Property, @ParameterizedTest annotations */
    readonly java: RegExp;
    /** TypeScript/JavaScript: it(, test(, describe( */
    readonly typescript: RegExp;
    /** Python: def test_, class Test */
    readonly python: RegExp;
};
/**
 * Agent types that perform implementation work.
 *
 * These agents can mark tasks as "implemented".
 */
export declare const TASK_EXECUTION_AGENTS: readonly string[];
/**
 * Agent types that trigger crash detection.
 *
 * If these agents complete without a parseable task ID in their output,
 * all executing_tasks are marked as "failed" with retry_count incremented.
 * This is aggressive but recoverable via retry.
 *
 * Matches Claude Code's update-task-status.sh crash detection.
 */
export declare const CRASH_DETECTION_AGENTS: readonly string[];
/**
 * Agent types that perform review work.
 *
 * These agents do NOT mark tasks as implemented.
 */
export declare const TASK_REVIEW_AGENTS: readonly string[];
/**
 * Completed task statuses that satisfy dependencies.
 *
 * Tasks with these statuses are considered "done" for dependency checking.
 */
export declare const COMPLETED_TASK_STATUSES: readonly string[];
export declare const ERRORS: {
    readonly DIRECT_EDIT_BLOCKED: "BLOCKED: Direct edits not allowed during task-planner orchestration.\n\nUse the agent tool with the appropriate agent for implementation:\n  - code-implementer-agent for production code\n  - java-test-agent or ts-test-agent for tests\n  - frontend-agent for UI components\n\nThis ensures proper phase sequencing and review gates.";
    readonly STATE_FILE_WRITE_BLOCKED: (file: string) => string;
    readonly PHASE_ORDER_VIOLATION: (current: Phase, attempted: Phase) => string;
    readonly TASK_DEPENDENCY_VIOLATION: (taskId: string, deps: string[]) => string;
    readonly WAVE_ORDER_VIOLATION: (taskWave: number, currentWave: number) => string;
    readonly LOCK_ACQUISITION_FAILED: "Failed to acquire state file lock after 50 attempts.\n\nAnother process may be holding the lock. If this persists, manually remove the lock file.";
    readonly UNKNOWN_SKILL_BLOCKED: (skillName: string) => string;
    readonly MISSING_ARTIFACT: (phase: Phase, missing: string) => string;
    readonly INVALID_ARTIFACT_PATH: (path: string) => string;
    readonly LEGACY_PATH_WARNING: (path: string) => string;
    readonly REVIEW_GATE_NOT_PASSED: (prevWave: number) => string;
    readonly REVIEW_GATE_BLOCKED: (prevWave: number, reasons: string[]) => string;
    readonly WAVE_GATE_TESTS_MISSING: (wave: number, missing: string[]) => string;
    readonly WAVE_GATE_NEW_TESTS_MISSING: (wave: number, missing: string[]) => string;
    readonly WAVE_GATE_REVIEWS_MISSING: (wave: number, unreviewed: string[]) => string;
    readonly WAVE_GATE_CRITICAL_FINDINGS: (wave: number, count: number) => string;
};
//# sourceMappingURL=constants.d.ts.map