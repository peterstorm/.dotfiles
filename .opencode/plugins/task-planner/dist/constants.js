/**
 * Task Planner Plugin - Constants
 *
 * Centralized configuration values for the task-planner plugin.
 */
// ============================================================================
// File Paths
// ============================================================================
/** State directory relative to project root */
export const STATE_DIR = ".opencode/state";
/** Active task graph filename */
export const TASK_GRAPH_FILENAME = "active_task_graph.json";
/** Lock file for state operations */
export const LOCK_FILENAME = ".task_graph.lock";
/** Specs directory relative to project root */
export const SPECS_DIR = ".opencode/specs";
/** Plans directory relative to project root */
export const PLANS_DIR = ".opencode/plans";
// ============================================================================
// Phase Configuration
// ============================================================================
/** Ordered list of phases in the workflow */
export const PHASE_ORDER = [
    "init",
    "brainstorm",
    "specify",
    "clarify",
    "architecture",
    "decompose",
    "execute",
];
/** Phases that can be skipped (non-mandatory) */
export const SKIPPABLE_PHASES = [
    "brainstorm",
    "clarify",
];
/** Phases that produce artifacts */
export const ARTIFACT_PHASES = [
    "brainstorm",
    "specify",
    "clarify",
    "architecture",
    "decompose",
];
// ============================================================================
// Skill-to-Phase Mapping (Phase 2)
// ============================================================================
/** Map skill names to their workflow phases */
export const SKILL_TO_PHASE = {
    // Brainstorm phase
    brainstorming: "brainstorm",
    // Specify phase (Claude and OpenCode variants)
    specify: "specify",
    "opencode-specify": "specify",
    // Clarify phase (Claude and OpenCode variants)
    clarify: "clarify",
    "opencode-clarify": "clarify",
    // Architecture phase
    "architecture-tech-lead": "architecture",
    // Decompose phase (Claude and OpenCode variants)
    "task-planner": "decompose",
    "opencode-task-planner": "decompose",
    // Execute phase (implementation skills)
    "code-implementer": "execute",
    "java-test-engineer": "execute",
    "ts-test-engineer": "execute",
    "nextjs-frontend-design": "execute",
    "security-expert": "execute",
    "k8s-expert": "execute",
    "keycloak-expert": "execute",
    "dotfiles-expert": "execute",
    "remotion-best-practices": "execute",
    "vercel-react-best-practices": "execute",
    // Execute phase (review/validation skills - Claude and OpenCode variants)
    "spec-check": "execute",
    "opencode-spec-check": "execute",
    "review-skill": "execute",
    "wave-gate": "execute",
    "opencode-wave-gate": "execute",
};
/** Skills exempt from phase validation (utility skills) */
export const PHASE_EXEMPT_SKILLS = [
    "find-skills",
    "writing-clearly-and-concisely",
    "marketing-ideas",
    "marketing-psychology",
    "copy-editing",
    "copywriting",
    // All marketing-* skills
    "product-marketing-context",
    "content-strategy",
    "social-content",
    "email-sequence",
    "paid-ads",
    "analytics-tracking",
    "seo-audit",
    "schema-markup",
    "programmatic-seo",
    "competitor-alternatives",
    "referral-program",
    "launch-strategy",
    "pricing-strategy",
    "free-tool-strategy",
    "ab-test-setup",
    "popup-cro",
    "form-cro",
    "page-cro",
    "signup-flow-cro",
    "onboarding-cro",
    "paywall-upgrade-cro",
    "ux-conversion",
    "conversion-copy",
];
/** Valid phase transitions */
export const VALID_TRANSITIONS = {
    init: ["brainstorm", "specify"],
    brainstorm: ["specify"],
    specify: ["clarify", "architecture"],
    clarify: ["architecture"],
    architecture: ["decompose"],
    decompose: ["execute"],
    execute: ["execute"],
};
// ============================================================================
// Phase Completion Patterns (Phase 2)
// ============================================================================
/** Patterns to detect phase completion in message content */
export const PHASE_COMPLETION_PATTERNS = {
    init: /^$/, // init never "completes" via pattern
    brainstorm: /(?:brainstorm(?:ing)?|exploration)\s+(?:is\s+)?(?:complete|done|finished)/i,
    specify: /spec(?:ification)?\s+(?:is\s+)?(?:complete|written|created|saved)|(?:created|wrote)\s+(?:the\s+)?spec/i,
    clarify: /clarif(?:y|ication)\s+(?:is\s+)?(?:complete|resolved|done)/i,
    architecture: /(?:architecture|design|plan)\s+(?:is\s+)?(?:complete|done|created)|(?:plan|design)\s+(?:has\s+been\s+)?created/i,
    decompose: /(?:decompos(?:e|ition)|tasks?)\s+(?:is\s+)?(?:complete|created|defined)|tasks?\s+(?:have\s+been\s+)?(?:created|defined)/i,
    execute: /^$/, // execute phase handled differently
};
/** Pattern to extract artifact file paths from messages */
export const ARTIFACT_PATH_PATTERN = /(?:saved|created|wrote|generated)\s+(?:to\s+)?['"]?([^\s'"]+\.md)['"]?/i;
/** Pattern to count clarification markers in spec files */
export const CLARIFICATION_MARKER_PATTERN = /\[NEEDS CLARIFICATION\]/g;
/** Threshold for auto-skipping clarify phase */
export const CLARIFY_MARKER_THRESHOLD = 3;
/** Allowed artifact path prefixes (for security) */
export const ALLOWED_ARTIFACT_PATHS = [
    /^\.opencode\/specs\//,
    /^\.opencode\/plans\//,
    /^\.claude\/specs\//, // Legacy, with deprecation warning
    /^\.claude\/plans\//, // Legacy, with deprecation warning
];
// ============================================================================
// Debounce Configuration (Phase 2)
// ============================================================================
/** Debounce time for session.idle phase advancement checks (ms) */
export const PHASE_ADVANCEMENT_DEBOUNCE_MS = 500;
// ============================================================================
// Tool Blocking
// ============================================================================
/** Tools blocked during orchestration (direct edits not allowed) */
export const BLOCKED_TOOLS = [
    "edit",
    "write",
    "Edit",
    "Write",
];
/** File patterns for state files that should be protected from Bash writes */
export const PROTECTED_STATE_PATTERNS = [
    /\.opencode\/state\/.*\.json$/,
    /\.opencode\/specs\/.*\.md$/,
    /\.opencode\/plans\/.*\.md$/,
    // Legacy Claude paths (for migration compatibility)
    /\.claude\/state\/.*\.json$/,
    /\.claude\/specs\/.*\.md$/,
    /\.claude\/plans\/.*\.md$/,
];
/** Bash commands that write to files */
export const BASH_WRITE_PATTERNS = [
    /\becho\b.*>/,
    /\bprintf\b.*>/,
    /\bcat\b.*>/,
    /\btee\b/,
    /\bcp\b/,
    /\bmv\b/,
    /\brm\b/,
    /\bsed\b.*-i/,
    /\bawk\b.*>/,
];
// ============================================================================
// Agent Configuration
// ============================================================================
/** Agent types that perform implementation work */
export const IMPLEMENTATION_AGENTS = [
    "code-implementer-agent",
    "java-test-agent",
    "ts-test-agent",
    "frontend-agent",
];
/** Agent types that perform review/validation work */
export const REVIEW_AGENTS = [
    "reviewer-agent",
    "spec-check-agent",
];
// ============================================================================
// Task ID Patterns
// ============================================================================
/** Pattern to extract task ID from text (e.g., "T1", "T2", "Task 3") */
export const TASK_ID_PATTERN = /\b(?:T|Task\s*)(\d+)\b/i;
/** Pattern to extract multiple task IDs */
export const TASK_ID_GLOBAL_PATTERN = /\b(?:T|Task\s*)(\d+)\b/gi;
// ============================================================================
// Review Findings Patterns
// ============================================================================
/** Pattern to identify CRITICAL findings in review output */
export const CRITICAL_FINDING_PATTERN = /^\s*(?:CRITICAL|🚨\s*CRITICAL):\s*(.+)$/gm;
/** Pattern to identify ADVISORY findings in review output */
export const ADVISORY_FINDING_PATTERN = /^\s*(?:ADVISORY|💡\s*ADVISORY):\s*(.+)$/gm;
/** Pattern to identify spec-check findings */
export const SPEC_CHECK_FINDING_PATTERN = /^\s*\[(\w+)\]\s*(.+)$/gm;
// ============================================================================
// Test Detection Patterns
// ============================================================================
/** File patterns that indicate test files */
export const TEST_FILE_PATTERNS = [
    /\.test\.[jt]sx?$/,
    /\.spec\.[jt]sx?$/,
    /Test\.java$/,
    /IT\.java$/,
    /Tests?\.kt$/,
    /__tests__\//,
    /src\/test\//,
];
/** Patterns that indicate new test methods in diff output */
export const NEW_TEST_METHOD_PATTERNS = [
    /^\+\s*(?:@Test|it\(|test\(|describe\()/m,
    /^\+\s*(?:fun\s+\w+Test|void\s+test\w+)/m,
];
// ============================================================================
// Timing Configuration
// ============================================================================
/** Lock acquisition timeout in milliseconds */
export const LOCK_TIMEOUT_MS = 5000;
/** Lock retry interval in milliseconds */
export const LOCK_RETRY_INTERVAL_MS = 100;
/** Maximum lock acquisition attempts */
export const MAX_LOCK_ATTEMPTS = 50;
/** Stale agent tracking file age in minutes */
export const STALE_AGENT_MINUTES = 60;
// ============================================================================
// Phase 3: Task Execution Constants
// ============================================================================
/**
 * Test evidence patterns for different test frameworks.
 *
 * Used to extract test results from agent output/transcripts.
 * Each pattern captures the evidence string for logging.
 */
export const TEST_EVIDENCE_PATTERNS = {
    /**
     * Maven/Java: "Tests run: X, Failures: 0, Errors: 0"
     * Also handles markdown bold: "Tests run: **128**, Failures: **0**, Errors: **0**"
     */
    maven: {
        success: /BUILD SUCCESS/i,
        results: /Tests run:\s*\*{0,2}(\d+)\*{0,2},\s*Failures:\s*\*{0,2}0\*{0,2},\s*Errors:\s*\*{0,2}0\*{0,2}/,
    },
    /**
     * Node/Mocha: "N passing" without "N failing"
     */
    mocha: {
        passing: /(\d+)\s+passing/i,
        failing: /(\d+)\s+failing/i,
    },
    /**
     * Vitest: "Tests X passed" or "Test Files X passed"
     */
    vitest: {
        passed: /Tests?\s+(\d+)\s+passed/i,
        failed: /Tests?\s+(\d+)\s+failed/i,
    },
    /**
     * pytest: "X passed" without "X failed"
     */
    pytest: {
        passed: /(\d+)\s+passed/i,
        failed: /(\d+)\s+failed/i,
    },
    /**
     * JUnit: XML-style output or "N tests completed"
     */
    junit: {
        success: /(\d+)\s+tests?\s+completed/i,
    },
};
/**
 * Patterns to detect new test methods in git diff output.
 *
 * Each pattern matches added lines (starting with +) that indicate
 * a new test method was created.
 */
export const NEW_TEST_PATTERNS = {
    /** Java: @Test, @Property, @ParameterizedTest annotations */
    java: /^\+.*@(Test|Property|ParameterizedTest)\b/m,
    /** TypeScript/JavaScript: it(, test(, describe( */
    typescript: /^\+.*\s(it|test|describe)\(/m,
    /** Python: def test_, class Test */
    python: /^\+.*(def test_|class Test)/m,
};
/**
 * Agent types that perform implementation work.
 *
 * These agents can mark tasks as "implemented".
 */
export const TASK_EXECUTION_AGENTS = [
    "code-implementer-agent",
    "java-test-agent",
    "ts-test-agent",
    "frontend-agent",
    "general",
];
/**
 * Agent types that perform review work.
 *
 * These agents do NOT mark tasks as implemented.
 */
export const TASK_REVIEW_AGENTS = [
    "reviewer-agent",
    "spec-check-agent",
];
/**
 * Completed task statuses that satisfy dependencies.
 *
 * Tasks with these statuses are considered "done" for dependency checking.
 */
export const COMPLETED_TASK_STATUSES = [
    "implemented",
    "completed",
];
// ============================================================================
// Error Messages
// ============================================================================
export const ERRORS = {
    DIRECT_EDIT_BLOCKED: `BLOCKED: Direct edits not allowed during task-planner orchestration.

Use the agent tool with the appropriate agent for implementation:
  - code-implementer-agent for production code
  - java-test-agent or ts-test-agent for tests
  - frontend-agent for UI components

This ensures proper phase sequencing and review gates.`,
    STATE_FILE_WRITE_BLOCKED: (file) => `BLOCKED: Cannot write to state file "${file}" via Bash.

State files must be modified through the task-planner plugin's state manager
to ensure proper locking and consistency.`,
    PHASE_ORDER_VIOLATION: (current, attempted) => `BLOCKED: Cannot skip to phase "${attempted}" from "${current}".

The task-planner requires phases to be completed in order:
  ${PHASE_ORDER.join(" → ")}

Complete the current phase before proceeding.`,
    TASK_DEPENDENCY_VIOLATION: (taskId, deps) => `BLOCKED: Cannot execute task ${taskId} - dependencies not met.

The following tasks must be completed first:
  ${deps.join(", ")}`,
    WAVE_ORDER_VIOLATION: (taskWave, currentWave) => `BLOCKED: Cannot execute task from wave ${taskWave} while still in wave ${currentWave}.

Complete all tasks in wave ${currentWave} before proceeding to wave ${taskWave}.`,
    LOCK_ACQUISITION_FAILED: `Failed to acquire state file lock after ${MAX_LOCK_ATTEMPTS} attempts.

Another process may be holding the lock. If this persists, manually remove the lock file.`,
    // Phase 2 errors
    UNKNOWN_SKILL_BLOCKED: (skillName) => `BLOCKED: Unrecognized skill "${skillName}" during task-planner orchestration.

Current phase requires a recognized workflow skill.
Complete the current phase before using utility skills.

Recognized phase skills:
  brainstorming, specify, clarify, architecture-tech-lead,
  code-implementer, java-test-engineer, ts-test-engineer, etc.`,
    MISSING_ARTIFACT: (phase, missing) => `BLOCKED: Cannot enter ${phase} phase - missing prerequisite.

Required: ${missing}

Complete the prerequisite phase first.`,
    INVALID_ARTIFACT_PATH: (path) => `BLOCKED: Invalid artifact path "${path}".

Artifacts must be in:
  .opencode/specs/**/*.md
  .opencode/plans/**/*.md`,
    LEGACY_PATH_WARNING: (path) => `WARNING: Legacy .claude/ path detected: ${path}
Consider migrating to .opencode/ directory structure.`,
    // Phase 3 errors
    REVIEW_GATE_NOT_PASSED: (prevWave) => `BLOCKED: Wave ${prevWave} review gate not passed.

Run /wave-gate to complete tests, reviews, and advance to the next wave.`,
    REVIEW_GATE_BLOCKED: (prevWave, reasons) => `BLOCKED: Wave ${prevWave} is BLOCKED due to:
${reasons.map((r) => `  - ${r}`).join("\n")}

Fix the issues and re-run /wave-gate.`,
    WAVE_GATE_TESTS_MISSING: (wave, missing) => `FAILED: Not all wave ${wave} tasks have test evidence.

Missing evidence: ${missing.join(", ")}

Test evidence is captured from agent output when tasks complete.
Re-spawn agents that failed to run tests.`,
    WAVE_GATE_NEW_TESTS_MISSING: (wave, missing) => `FAILED: Not all wave ${wave} tasks satisfied new-test requirement.

Missing new-test evidence: ${missing.join(", ")}

Tasks must write NEW tests unless new_tests_required=false.
Re-spawn agents that failed to write tests.`,
    WAVE_GATE_REVIEWS_MISSING: (wave, unreviewed) => `FAILED: Not all wave ${wave} tasks have been reviewed.

Unreviewed: ${unreviewed.join(", ")}

Spawn review-invoker agents for unreviewed tasks.`,
    WAVE_GATE_CRITICAL_FINDINGS: (wave, count) => `FAILED: Wave ${wave} code review has ${count} critical findings.

Fix critical findings before completing the wave gate.`,
};
//# sourceMappingURL=constants.js.map