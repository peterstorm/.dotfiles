/**
 * Task Planner Plugin - Phase Advancement Hook
 *
 * Detects phase completion via message content patterns and automatically
 * advances the current_phase in state. Handles special logic like
 * auto-skipping clarify when NEEDS CLARIFICATION markers are ≤ 3.
 *
 * This hook runs on message.updated and session.idle events.
 */

import { readFile } from "fs/promises";
import { existsSync } from "fs";
import { join } from "path";
import type { TaskGraph, Phase, PhaseAdvancement } from "../types";
import {
  PHASE_COMPLETION_PATTERNS,
  ARTIFACT_PATH_PATTERN,
  CLARIFICATION_MARKER_PATTERN,
  CLARIFY_MARKER_THRESHOLD,
  PHASE_ORDER,
} from "../constants";
import type { StateManager } from "../utils/state-manager";

// ============================================================================
// Main Advancement Function
// ============================================================================

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
export async function advancePhase(
  content: string,
  taskGraph: TaskGraph,
  stateManager: StateManager,
  projectDir: string
): Promise<PhaseAdvancement | null> {
  // 1. Detect completed phase from content
  const completedPhase = detectCompletedPhase(content, taskGraph.current_phase);
  if (!completedPhase) {
    return null;
  }

  // 2. Extract artifact path from message
  const artifact = extractArtifactPath(content);

  // 3. Determine next phase with special handling
  let nextPhase = getNextPhase(completedPhase);
  let clarifySkipped = false;

  // 4. Special handling for specify → clarify/architecture
  if (completedPhase === "specify" && nextPhase === "clarify") {
    // Check if we should auto-skip clarify
    const specPath = resolveArtifactPath(artifact, projectDir);
    const markerCount = await countClarificationMarkers(specPath);

    console.log(
      `[task-planner] Clarification markers in spec: ${markerCount} (threshold: ${CLARIFY_MARKER_THRESHOLD})`
    );

    if (markerCount <= CLARIFY_MARKER_THRESHOLD) {
      // Auto-skip clarify phase
      await stateManager.addSkippedPhase("clarify");
      nextPhase = "architecture";
      clarifySkipped = true;
      console.log("[task-planner] clarify auto-skipped: markers ≤ threshold");
    }
  }

  // 5. Update state atomically
  await stateManager.advancePhase(completedPhase, nextPhase, artifact);

  console.log(
    `[task-planner] Phase advanced: ${completedPhase} → ${nextPhase}`
  );

  return {
    completedPhase,
    newPhase: nextPhase,
    artifact,
    clarifySkipped,
  };
}

// ============================================================================
// Completion Detection
// ============================================================================

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
export function detectCompletedPhase(
  content: string,
  currentPhase: Phase
): Phase | null {
  // Only check the pattern for the current phase
  // This prevents detecting "specify complete" when we're in brainstorm
  const pattern = PHASE_COMPLETION_PATTERNS[currentPhase];

  if (!pattern || pattern.source === "^$") {
    // Empty pattern means phase doesn't complete via pattern detection
    return null;
  }

  if (pattern.test(content)) {
    return currentPhase;
  }

  return null;
}

/**
 * Get the next phase in the workflow.
 *
 * @param phase - Current phase
 * @returns Next phase in sequence
 */
export function getNextPhase(phase: Phase): Phase {
  const index = PHASE_ORDER.indexOf(phase);
  if (index === -1 || index >= PHASE_ORDER.length - 1) {
    return "execute"; // Stay in execute or default to it
  }
  return PHASE_ORDER[index + 1] as Phase;
}

// ============================================================================
// Artifact Extraction
// ============================================================================

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
export function extractArtifactPath(content: string): string {
  const match = content.match(ARTIFACT_PATH_PATTERN);
  if (match && match[1]) {
    return match[1];
  }
  return "completed";
}

/**
 * Resolve artifact path to full path.
 *
 * @param artifact - Relative artifact path
 * @param projectDir - Project directory
 * @returns Full path to artifact
 */
export function resolveArtifactPath(
  artifact: string,
  projectDir: string
): string {
  if (artifact === "completed") {
    return "";
  }
  return join(projectDir, artifact);
}

// ============================================================================
// Clarification Marker Counting
// ============================================================================

/**
 * Count NEEDS CLARIFICATION markers in a spec file.
 *
 * Used to determine if clarify phase should be auto-skipped.
 * If markers ≤ CLARIFY_MARKER_THRESHOLD, clarify is skipped.
 *
 * @param specPath - Path to specification file
 * @returns Number of markers found, or 0 if file not readable
 */
export async function countClarificationMarkers(
  specPath: string
): Promise<number> {
  if (!specPath || !existsSync(specPath)) {
    console.warn(
      `[task-planner] Spec file not found for marker counting: ${specPath}`
    );
    return 0;
  }

  try {
    const content = await readFile(specPath, "utf-8");
    const matches = content.match(CLARIFICATION_MARKER_PATTERN);
    return matches ? matches.length : 0;
  } catch (error) {
    console.warn(`[task-planner] Could not read spec file: ${specPath}`, error);
    return 0;
  }
}

// ============================================================================
// Additional Detection Helpers
// ============================================================================

/**
 * Check if content indicates any phase completion.
 *
 * Useful for session.idle where we might check against all patterns.
 *
 * @param content - Message content
 * @returns Detected phase or null
 */
export function detectAnyPhaseCompletion(content: string): Phase | null {
  for (const [phase, pattern] of Object.entries(PHASE_COMPLETION_PATTERNS)) {
    if (pattern.source !== "^$" && pattern.test(content)) {
      return phase as Phase;
    }
  }
  return null;
}

/**
 * Check if message indicates task completion (for execute phase).
 *
 * The execute phase doesn't complete via standard patterns - it completes
 * when all tasks are done. This helper detects task completion messages.
 *
 * @param content - Message content
 * @returns Task ID if task completion detected, null otherwise
 */
export function detectTaskCompletion(content: string): string | null {
  // Look for patterns like "T1 implemented", "Task 3 complete"
  const taskCompletePattern =
    /\b(?:T|Task\s*)(\d+)\b.*(?:complete|implemented|done|finished)/i;
  const match = content.match(taskCompletePattern);
  return match ? `T${match[1]}` : null;
}
