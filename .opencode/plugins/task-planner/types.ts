/**
 * Task Planner Plugin - Type Definitions
 *
 * These types mirror the Claude Code task-planner state structure
 * to ensure compatibility during migration.
 */

// ============================================================================
// Enums & Literal Types
// ============================================================================

export type TaskStatus =
  | "pending"
  | "in_progress"
  | "implemented"
  | "completed"
  | "failed"
  | "cancelled";

export type Phase =
  | "init"
  | "brainstorm"
  | "specify"
  | "clarify"
  | "architecture"
  | "decompose"
  | "execute";

export type ReviewVerdict =
  | "PASSED"
  | "BLOCKED"
  | "EVIDENCE_CAPTURE_FAILED"
  | "UNKNOWN";

export type AgentType =
  | "code-implementer-agent"
  | "java-test-agent"
  | "ts-test-agent"
  | "frontend-agent"
  | "reviewer-agent"
  | "spec-check-agent"
  | "general";

// ============================================================================
// Task & Wave Types
// ============================================================================

export interface Task {
  /** Unique task identifier, e.g., "T1", "T2" */
  id: string;

  /** Human-readable task description */
  description: string;

  /** Wave number (1-based) for parallel execution grouping */
  wave: number;

  /** Current task status */
  status: TaskStatus;

  /** Agent type to use for this task */
  agent: AgentType | string;

  /** Task IDs this task depends on (must be completed first) */
  depends_on: string[];

  /** References to specification sections this task implements */
  spec_anchors?: string[];

  /** Whether this task requires new tests to be written */
  new_tests_required?: boolean;

  // ---- Set by hooks during execution ----

  /** Git SHA when task started (for diff tracking) */
  start_sha?: string;

  /** Whether tests passed after implementation */
  tests_passed?: boolean;

  /** Evidence of test execution (e.g., "42 tests passed") */
  test_evidence?: string;

  /** Whether new tests were written (verified via git diff) */
  new_tests_written?: boolean;

  /** Evidence of new test methods added */
  new_test_evidence?: string;

  /** Review status for this task */
  review_status?: "pending" | "passed" | "blocked" | "evidence_capture_failed";

  /** Critical review findings that block progress */
  critical_findings?: string[];

  /** Advisory review findings (non-blocking) */
  advisory_findings?: string[];

  /** Files modified during this task's execution */
  files_modified?: string[];

  /** Reason for task failure (set by crash detection or review) */
  failure_reason?: string;

  /** Number of retry attempts (incremented on failure) */
  retry_count?: number;
}

export interface WaveGate {
  /** All tasks in this wave have status "implemented" */
  impl_complete?: boolean;

  /** All tests pass for this wave */
  tests_passed?: boolean;

  /** All reviews complete for this wave */
  reviews_complete?: boolean;

  /** Wave is blocked due to critical findings */
  blocked?: boolean;

  /** Timestamp when gate was checked */
  checked_at?: string;
}

// ============================================================================
// Spec Check Types
// ============================================================================

export interface SpecCheck {
  /** Wave number this check was run for */
  wave: number;

  /** ISO timestamp when check was run */
  run_at: string;

  /** Count of critical findings */
  critical_count: number;

  /** Count of high priority findings */
  high_count: number;

  /** List of critical findings */
  critical_findings: string[];

  /** List of high priority findings */
  high_findings: string[];

  /** List of medium priority findings */
  medium_findings: string[];

  /** Overall verdict */
  verdict: ReviewVerdict;
}

// ============================================================================
// Main Task Graph Type
// ============================================================================

export interface TaskGraph {
  // ---- Plan metadata ----

  /** Title of the feature/plan */
  title: string;

  /** Path to the specification file */
  spec_file: string;

  /** Path to the plan/decomposition file */
  plan_file: string;

  /** GitHub issue number if created */
  github_issue?: number;

  // ---- Phase tracking ----

  /** Current phase in the workflow */
  current_phase: Phase;

  /** Artifacts produced by each phase (file paths) */
  phase_artifacts: Partial<Record<Phase, string | null>>;

  /** Phases that were explicitly skipped */
  skipped_phases: Phase[];

  // ---- Wave execution ----

  /** Current wave being executed (1-based) */
  current_wave: number;

  /** All tasks in the plan */
  tasks: Task[];

  /** Task IDs currently being executed */
  executing_tasks: string[];

  /** Gate status for each wave */
  wave_gates: Record<number, WaveGate>;

  // ---- Quality checks ----

  /** Latest spec check results */
  spec_check?: SpecCheck;

  // ---- Timestamps ----

  /** ISO timestamp when plan was created */
  created_at: string;

  /** ISO timestamp when plan was last updated */
  updated_at: string;
}

// ============================================================================
// Agent Tracking Types
// ============================================================================

export interface AgentContext {
  /** Unique identifier for this agent instance */
  agentId: string;

  /** Type of agent (maps to skill/role) */
  agentType: AgentType | string;

  /** Task ID being worked on (if applicable) */
  taskId?: string;

  /** ISO timestamp when agent started */
  startedAt: string;

  /** Session ID for cross-reference */
  sessionId?: string;
}

// ============================================================================
// Plugin Event Types (OpenCode-specific)
// These types match the @opencode-ai/plugin API
// ============================================================================

/**
 * Input for tool.execute.before hook.
 * This is the first parameter passed by OpenCode.
 */
export interface ToolExecuteBeforeInput {
  /** Tool name being invoked */
  tool: string;

  /** Session ID */
  sessionID: string;

  /** Call ID for this invocation */
  callID: string;
}

/**
 * Output for tool.execute.before hook.
 * This is the second parameter passed by OpenCode - mutable.
 */
export interface ToolExecuteBeforeOutput {
  /** Tool arguments (can be modified) */
  args: Record<string, unknown>;
}

/**
 * Input for tool.execute.after hook.
 * This is the first parameter passed by OpenCode.
 */
export interface ToolExecuteAfterInput {
  /** Tool name being invoked */
  tool: string;

  /** Session ID */
  sessionID: string;

  /** Call ID for this invocation */
  callID: string;
}

/**
 * Output for tool.execute.after hook.
 * This is the second parameter passed by OpenCode - mutable.
 */
export interface ToolExecuteAfterOutput {
  /** Title of the tool execution */
  title: string;

  /** Tool output */
  output: string;

  /** Additional metadata */
  metadata: unknown;
}

/**
 * Legacy type for internal hook functions.
 * Used by existing hook implementations that take combined input.
 */
export interface ToolExecuteInput {
  /** Tool name being invoked */
  tool: string;

  /** Tool arguments */
  args: Record<string, unknown>;
}

export interface ToolExecuteOutput {
  /** Modified arguments (if any) */
  args: Record<string, unknown>;
}

export interface SessionContext {
  /** Session identifier */
  id: string;

  /** Project directory */
  directory: string;

  /** Messages in this session (if available) */
  messages?: Message[];
}

export interface Message {
  /** Message role */
  role: "user" | "assistant" | "system";

  /** Message content */
  content: string;

  /** ISO timestamp */
  timestamp?: string;
}

// ============================================================================
// State Manager Types
// ============================================================================

export interface StateManagerOptions {
  /** Project directory root */
  projectDir: string;

  /** State subdirectory (default: ".opencode/state") */
  stateDir?: string;

  /** Lock timeout in milliseconds (default: 5000) */
  lockTimeout?: number;
}

// ============================================================================
// Phase 2: Phase Enforcement Types
// ============================================================================

/**
 * Result of phase advancement operation.
 *
 * Returned when a phase is detected as complete and the workflow
 * advances to the next phase.
 */
export interface PhaseAdvancement {
  /** The phase that was completed */
  completedPhase: Phase;

  /** The new current phase */
  newPhase: Phase;

  /** Path to artifact produced (or "completed" if none) */
  artifact: string;

  /** Whether clarify phase was auto-skipped (markers ≤ 3) */
  clarifySkipped?: boolean;
}

/**
 * Result of artifact prerequisite check.
 *
 * Used to verify that required artifacts exist before
 * allowing a phase transition.
 */
export interface ArtifactPrerequisiteResult {
  /** Whether prerequisites are met */
  valid: boolean;

  /** Description of missing prerequisite (if invalid) */
  missing?: string;
}

/**
 * Validation result for phase transitions.
 *
 * Used to determine if a skill invocation should be
 * allowed based on the current workflow phase.
 */
export interface PhaseTransitionResult {
  /** Whether transition is allowed */
  allowed: boolean;

  /** Reason for blocking (if not allowed) */
  reason?: string;

  /** Suggested next steps */
  suggestion?: string;
}

// ============================================================================
// Phase 3: Task Execution Types
// ============================================================================

/**
 * Result of task execution validation.
 *
 * Returned by validateTaskExecution to indicate whether a task
 * invocation should be allowed.
 */
export interface TaskExecutionResult {
  /** Whether execution is allowed */
  allowed: boolean;

  /** Task ID being executed (if identified) */
  taskId?: string;

  /** Reason for blocking (if not allowed) */
  reason?: string;

  /** Suggested next steps */
  suggestion?: string;

  /** Start SHA captured for new-test verification */
  startSha?: string;
}

/**
 * Test evidence extracted from agent output.
 *
 * Captures proof that tests were run and passed.
 */
export interface TestEvidence {
  /** Whether tests passed */
  passed: boolean;

  /** Test framework detected (maven, vitest, pytest, etc.) */
  framework?: string;

  /** Evidence string (e.g., "Tests run: 42, Failures: 0, Errors: 0") */
  evidence?: string;

  /** Number of tests that passed */
  testCount?: number;
}

/**
 * Evidence of new test methods added.
 *
 * Used to verify that implementation tasks wrote new tests,
 * not just reran existing ones.
 */
export interface NewTestEvidence {
  /** Whether new tests were written */
  written: boolean;

  /** Total count of new test methods detected */
  count: number;

  /** Evidence string with breakdown by language */
  evidence?: string;
}

/**
 * Result of wave gate verification.
 *
 * Summarizes whether all gate requirements are met
 * for advancing to the next wave.
 */
export interface WaveGateResult {
  /** Whether gate passed */
  passed: boolean;

  /** Wave number being verified */
  wave: number;

  /** Individual check results */
  checks: {
    /** All tasks have test evidence */
    testsPassed: boolean;

    /** All tasks that require new tests have them */
    newTestsVerified: boolean;

    /** All tasks have been reviewed */
    reviewsComplete: boolean;

    /** No critical review findings */
    noCriticalFindings: boolean;

    /** Spec alignment verified (if applicable) */
    specAligned?: boolean;
  };

  /** Tasks that failed specific checks */
  failedTasks?: {
    missingTestEvidence?: string[];
    missingNewTests?: string[];
    unreviewed?: string[];
    criticalFindings?: string[];
  };
}

/**
 * Input for task-related tool invocations.
 *
 * Extended version of ToolExecuteInput with task-specific fields.
 */
export interface TaskToolInput {
  /** Tool name (typically "task" or "Task") */
  tool: string;

  /** Tool arguments */
  args: {
    /** Task prompt/description */
    prompt?: string;

    /** Short description */
    description?: string;

    /** Agent type to use */
    subagent_type?: string;

    /** Other arguments */
    [key: string]: unknown;
  };
}

/**
 * Context for task status updates.
 *
 * Passed to update-task-status hook with agent completion info.
 */
export interface TaskCompletionContext {
  /** Session ID */
  sessionId: string;

  /** Agent transcript content (parsed from transcript file) */
  transcript?: string;

  /** Agent type that completed */
  agentType?: string;

  /** Files modified during task (parsed from transcript) */
  filesModified?: string[];

  /** Task ID being completed */
  taskId?: string;
}
