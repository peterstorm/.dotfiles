/**
 * Task Planner Plugin - Phase Order Validation Hook
 *
 * Intercepts skill tool invocations and blocks those that would skip
 * required phases or violate the workflow order.
 *
 * This hook runs on tool.execute.before for "skill" tool invocations.
 */
import type { TaskGraph, ToolExecuteInput, Phase, ArtifactPrerequisiteResult } from "../types.js";
/**
 * Validate that a skill invocation respects the phase order.
 *
 * This is the main entry point called from the plugin's tool.execute.before
 * handler. It blocks skill invocations that would violate the workflow.
 *
 * @param input - The tool execution input from OpenCode
 * @param taskGraph - The current task graph state (null if no orchestration)
 * @param projectDir - Project directory for artifact checks
 * @throws Error if the skill would violate phase ordering
 */
export declare function validatePhaseOrder(input: ToolExecuteInput, taskGraph: TaskGraph | null, projectDir: string): void;
/**
 * Check if a phase transition is valid.
 *
 * A transition is valid if:
 * - The target phase is in the VALID_TRANSITIONS list for the current phase
 * - OR the target phase is the same as current (staying in phase)
 *
 * Multi-step transitions are NOT allowed directly. Each phase must be
 * completed (or skipped) before moving to the next.
 *
 * @param from - Current phase
 * @param to - Target phase
 * @param skippedPhases - Phases that have been explicitly skipped (unused in current impl)
 * @returns true if transition is allowed
 */
export declare function isValidTransition(from: Phase, to: Phase, _skippedPhases?: Phase[]): boolean;
/**
 * Check if artifact prerequisites are met for a phase.
 *
 * Different phases require different artifacts:
 * - clarify: requires spec file from specify phase
 * - architecture: requires spec file from specify phase
 * - decompose: requires plan file from architecture phase
 * - execute: requires plan file from architecture phase
 *
 * @param targetPhase - Phase being transitioned to
 * @param taskGraph - Current task graph
 * @param projectDir - Project directory for file existence checks
 * @returns { valid: boolean; missing?: string }
 */
export declare function checkArtifactPrerequisites(targetPhase: Phase, taskGraph: TaskGraph, projectDir: string): ArtifactPrerequisiteResult;
/**
 * Check if a skill is exempt from phase validation.
 *
 * @param skillName - Normalized (lowercase) skill name
 * @returns true if skill is exempt
 */
export declare function isPhaseExempt(skillName: string): boolean;
/**
 * Get the phase for a skill name.
 *
 * @param skillName - Skill name (case-insensitive)
 * @returns Phase or undefined if not found
 */
export declare function getPhaseForSkill(skillName: string): Phase | undefined;
/**
 * Check if an artifact path is in an allowed location.
 *
 * @param path - Artifact path to check
 * @returns true if path is allowed
 */
export declare function isValidArtifactPath(path: string): boolean;
//# sourceMappingURL=validate-phase-order.d.ts.map