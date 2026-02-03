/**
 * Task Planner Plugin - Phase Order Validation Hook
 *
 * Intercepts skill tool invocations and blocks those that would skip
 * required phases or violate the workflow order.
 *
 * This hook runs on tool.execute.before for "skill" tool invocations.
 */
import { SKILL_TO_PHASE, PHASE_EXEMPT_SKILLS, VALID_TRANSITIONS, ALLOWED_ARTIFACT_PATHS, ERRORS, } from "../constants.js";
// ============================================================================
// Main Validation Function
// ============================================================================
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
export function validatePhaseOrder(input, taskGraph, projectDir) {
    // 1. Exit early if no orchestration active
    if (!taskGraph) {
        return;
    }
    // 2. Only check "skill" tool invocations
    if (input.tool.toLowerCase() !== "skill") {
        return;
    }
    // 3. Extract skill name from args
    const skillName = input.args.name;
    if (typeof skillName !== "string" || !skillName) {
        return;
    }
    // 4. Normalize skill name for comparison (case-insensitive)
    const normalizedSkillName = skillName.toLowerCase();
    // 5. Check if skill is phase-exempt (utility skills)
    if (isPhaseExempt(normalizedSkillName)) {
        return;
    }
    // 6. Map skill to target phase
    const targetPhase = getPhaseForSkill(normalizedSkillName);
    // 7. Handle unknown skills
    if (!targetPhase) {
        // Allow unknown skills during execute phase (e.g., custom domain skills)
        if (taskGraph.current_phase === "execute") {
            return;
        }
        throw new Error(ERRORS.UNKNOWN_SKILL_BLOCKED(skillName));
    }
    // 8. Check transition validity
    const currentPhase = taskGraph.current_phase;
    if (!isValidTransition(currentPhase, targetPhase, taskGraph.skipped_phases)) {
        throw new Error(ERRORS.PHASE_ORDER_VIOLATION(currentPhase, targetPhase));
    }
    // 9. Check artifact prerequisites
    const prereq = checkArtifactPrerequisites(targetPhase, taskGraph, projectDir);
    if (!prereq.valid) {
        throw new Error(ERRORS.MISSING_ARTIFACT(targetPhase, prereq.missing ?? "unknown prerequisite"));
    }
    // Validation passed - skill invocation is allowed
    console.log(`[task-planner] Phase validation passed: ${currentPhase} → ${targetPhase} (skill: ${skillName})`);
}
// ============================================================================
// Phase Transition Validation
// ============================================================================
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
export function isValidTransition(from, to, _skippedPhases = []) {
    // Same phase is always valid (e.g., execute → execute)
    if (from === to) {
        return true;
    }
    // Only allow direct transitions defined in VALID_TRANSITIONS
    const validTargets = VALID_TRANSITIONS[from];
    return validTargets !== undefined && validTargets.includes(to);
}
// ============================================================================
// Artifact Prerequisites
// ============================================================================
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
export function checkArtifactPrerequisites(targetPhase, taskGraph, projectDir) {
    const prerequisites = getPhasePrerequisites(targetPhase);
    for (const prereq of prerequisites) {
        const artifact = taskGraph.phase_artifacts?.[prereq.phase];
        // Check if artifact is recorded
        if (!artifact) {
            return {
                valid: false,
                missing: `${prereq.phase} phase artifact not recorded`,
            };
        }
        // "completed" means the phase was done but no file was produced
        if (artifact === "completed") {
            continue;
        }
        // Validate artifact path security
        if (!isValidArtifactPath(artifact)) {
            console.warn(ERRORS.INVALID_ARTIFACT_PATH(artifact));
            // Don't block, just warn - the file might still exist
        }
        // Check if artifact file exists on disk
        const fullPath = `${projectDir}/${artifact}`;
        try {
            const fs = require("fs");
            if (!fs.existsSync(fullPath)) {
                return {
                    valid: false,
                    missing: `${prereq.phase} artifact file not found: ${artifact}`,
                };
            }
        }
        catch {
            // If we can't check, allow and let later steps fail
            console.warn(`[task-planner] Could not verify artifact exists: ${artifact}`);
        }
    }
    return { valid: true };
}
/**
 * Get prerequisite phases and their artifact types for a target phase.
 */
function getPhasePrerequisites(phase) {
    switch (phase) {
        case "clarify":
            return [{ phase: "specify", type: "spec" }];
        case "architecture":
            return [{ phase: "specify", type: "spec" }];
        case "decompose":
            return [{ phase: "architecture", type: "plan" }];
        case "execute":
            return [{ phase: "architecture", type: "plan" }];
        default:
            return [];
    }
}
// ============================================================================
// Helper Functions
// ============================================================================
/**
 * Check if a skill is exempt from phase validation.
 *
 * @param skillName - Normalized (lowercase) skill name
 * @returns true if skill is exempt
 */
export function isPhaseExempt(skillName) {
    return PHASE_EXEMPT_SKILLS.some((exempt) => exempt.toLowerCase() === skillName);
}
/**
 * Get the phase for a skill name.
 *
 * @param skillName - Skill name (case-insensitive)
 * @returns Phase or undefined if not found
 */
export function getPhaseForSkill(skillName) {
    // Normalize to lowercase for comparison
    const normalizedName = skillName.toLowerCase();
    // Check all keys case-insensitively
    const entries = Object.entries(SKILL_TO_PHASE);
    for (const [key, value] of entries) {
        if (key.toLowerCase() === normalizedName) {
            return value;
        }
    }
    return undefined;
}
/**
 * Check if an artifact path is in an allowed location.
 *
 * @param path - Artifact path to check
 * @returns true if path is allowed
 */
export function isValidArtifactPath(path) {
    // Check against allowed patterns
    const isAllowed = ALLOWED_ARTIFACT_PATHS.some((pattern) => pattern.test(path));
    // Check for legacy .claude/ paths and warn
    if (path.startsWith(".claude/")) {
        console.warn(ERRORS.LEGACY_PATH_WARNING(path));
    }
    return isAllowed;
}
//# sourceMappingURL=validate-phase-order.js.map