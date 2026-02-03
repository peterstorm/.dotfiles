/**
 * Task Planner Plugin - Phase Advancement Hook
 *
 * Detects phase completion via message content patterns and automatically
 * advances the current_phase in state. Handles special logic like
 * auto-skipping clarify when NEEDS CLARIFICATION markers are ≤ 3.
 *
 * This hook runs on message.updated and session.idle events.
 */
import type { TaskGraph, Phase, PhaseAdvancement } from "../types.js";
import type { StateManager } from "../utils/state-manager.js";
/**
 * Check message content for phase completion and advance state.
 *
 * This is the main entry point called from message.updated and session.idle
 * handlers. It detects when a phase has been completed and advances the
 * workflow to the next phase.
 *
 * @param content - Message content from assistant
 * @param taskGraph - Current task graph
 * @param stateManager - State manager for updates
 * @param projectDir - Project directory for file operations
 * @returns Updated phase info or null if no advancement
 */
export declare function advancePhase(content: string, taskGraph: TaskGraph, stateManager: StateManager, projectDir: string): Promise<PhaseAdvancement | null>;
/**
 * Detect which phase was completed based on message patterns.
 *
 * Uses PHASE_COMPLETION_PATTERNS to match against message content.
 * Only checks patterns relevant to the current phase to avoid false positives.
 *
 * @param content - Message content to analyze
 * @param currentPhase - Current phase for context
 * @returns Detected completed phase or null
 */
export declare function detectCompletedPhase(content: string, currentPhase: Phase): Phase | null;
/**
 * Get the next phase in the workflow.
 *
 * @param phase - Current phase
 * @returns Next phase in sequence
 */
export declare function getNextPhase(phase: Phase): Phase;
/**
 * Extract artifact file path from message content.
 *
 * Looks for patterns like:
 * - "saved to .opencode/specs/xxx.md"
 * - "created .opencode/plans/xxx.md"
 * - "wrote '.opencode/specs/xxx.md'"
 *
 * @param content - Message content
 * @returns Extracted file path or "completed" if no path found
 */
export declare function extractArtifactPath(content: string): string;
/**
 * Resolve artifact path to full path.
 *
 * @param artifact - Relative artifact path
 * @param projectDir - Project directory
 * @returns Full path to artifact
 */
export declare function resolveArtifactPath(artifact: string, projectDir: string): string;
/**
 * Count NEEDS CLARIFICATION markers in a spec file.
 *
 * Used to determine if clarify phase should be auto-skipped.
 * If markers ≤ CLARIFY_MARKER_THRESHOLD, clarify is skipped.
 *
 * @param specPath - Path to specification file
 * @returns Number of markers found, or 0 if file not readable
 */
export declare function countClarificationMarkers(specPath: string): Promise<number>;
/**
 * Check if content indicates any phase completion.
 *
 * Useful for session.idle where we might check against all patterns.
 *
 * @param content - Message content
 * @returns Detected phase or null
 */
export declare function detectAnyPhaseCompletion(content: string): Phase | null;
/**
 * Check if message indicates task completion (for execute phase).
 *
 * The execute phase doesn't complete via standard patterns - it completes
 * when all tasks are done. This helper detects task completion messages.
 *
 * @param content - Message content
 * @returns Task ID if task completion detected, null otherwise
 */
export declare function detectTaskCompletion(content: string): string | null;
//# sourceMappingURL=advance-phase.d.ts.map