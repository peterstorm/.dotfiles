/**
 * Task Planner Plugin - Phase Order Validation Hook
 *
 * Intercepts skill tool invocations and blocks those that would skip
 * required phases or violate the workflow order.
 *
 * This hook runs on tool.execute.before for "skill" tool invocations.
 */

import type {
  TaskGraph,
  ToolExecuteInput,
  Phase,
  ArtifactPrerequisiteResult,
} from "../types";
import {
  SKILL_TO_PHASE,
  PHASE_EXEMPT_SKILLS,
  VALID_TRANSITIONS,
  ALLOWED_ARTIFACT_PATHS,
  ERRORS,
} from "../constants";

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
export function validatePhaseOrder(
  input: ToolExecuteInput,
  taskGraph: TaskGraph | null,
  projectDir: string
): void {
  // 1. Exit early if no orchestration active
  if (!taskGraph) {
    return;
  }

  // 2. Check for skill tool invocations (OpenCode uses "skill" tool)
  const toolName = input.tool.toLowerCase();
  
  // Handle "skill" tool invocations (skill loading)
  if (toolName === "skill") {
    const skillName = input.args.name;
    if (typeof skillName !== "string" || !skillName) {
      return;
    }
    validateSkillPhase(skillName, taskGraph, projectDir);
    return;
  }
  
  // Handle "task" tool invocations (agent spawning) - check for phase-related agents
  if (toolName === "task") {
    const subagentType = input.args.subagent_type;
    const prompt = input.args.prompt;
    
    // Try to detect phase from agent type or prompt
    if (typeof subagentType === "string" && subagentType) {
      validateAgentPhase(subagentType, String(prompt || ""), taskGraph, projectDir);
    }
    return;
  }
}

/**
 * Validate skill invocation against phase order.
 */
function validateSkillPhase(
  skillName: string,
  taskGraph: TaskGraph,
  projectDir: string
): void {
  // Normalize skill name for comparison (case-insensitive)
  const normalizedSkillName = skillName.toLowerCase();

  // Check if skill is phase-exempt (utility skills)
  if (isPhaseExempt(normalizedSkillName)) {
    return;
  }

  // Map skill to target phase
  const targetPhase = getPhaseForSkill(normalizedSkillName);

  // Handle unknown skills
  if (!targetPhase) {
    // Allow unknown skills during execute phase (e.g., custom domain skills)
    if (taskGraph.current_phase === "execute") {
      return;
    }
    throw new Error(ERRORS.UNKNOWN_SKILL_BLOCKED(skillName));
  }

  // Check transition validity
  const currentPhase = taskGraph.current_phase;
  if (!isValidTransition(currentPhase, targetPhase, taskGraph.skipped_phases)) {
    throw new Error(ERRORS.PHASE_ORDER_VIOLATION(currentPhase, targetPhase));
  }

  // Check artifact prerequisites
  const prereq = checkArtifactPrerequisites(targetPhase, taskGraph, projectDir);
  if (!prereq.valid) {
    throw new Error(ERRORS.MISSING_ARTIFACT(targetPhase, prereq.missing ?? "unknown prerequisite"));
  }

  // Validation passed
  console.log(
    `[task-planner] Phase validation passed: ${currentPhase} → ${targetPhase} (skill: ${skillName})`
  );
}

/**
 * Validate agent spawn against phase order.
 * Maps agent types to their corresponding phases.
 * 
 * SECURITY: Blocks unknown agents during non-execute phases to prevent
 * bypassing workflow via empty/unknown subagent_type.
 */
function validateAgentPhase(
  agentType: string,
  prompt: string,
  taskGraph: TaskGraph,
  projectDir: string
): void {
  // Map agent type to phase
  const targetPhase = getPhaseForAgent(agentType, prompt);
  
  // Block unknown agents during non-execute phases
  // This prevents bypassing workflow by using empty/unknown agent types
  if (!targetPhase) {
    if (taskGraph.current_phase !== "execute") {
      throw new Error(ERRORS.UNKNOWN_SKILL_BLOCKED(agentType));
    }
    // Allow unknown agents during execute phase (might be custom domain agents)
    return;
  }

  // Check transition validity
  const currentPhase = taskGraph.current_phase;
  if (!isValidTransition(currentPhase, targetPhase, taskGraph.skipped_phases)) {
    throw new Error(ERRORS.PHASE_ORDER_VIOLATION(currentPhase, targetPhase));
  }

  // Check artifact prerequisites
  const prereq = checkArtifactPrerequisites(targetPhase, taskGraph, projectDir);
  if (!prereq.valid) {
    throw new Error(ERRORS.MISSING_ARTIFACT(targetPhase, prereq.missing ?? "unknown prerequisite"));
  }

  console.log(
    `[task-planner] Phase validation passed: ${currentPhase} → ${targetPhase} (agent: ${agentType})`
  );
}

/**
 * Map agent type to workflow phase.
 */
function getPhaseForAgent(agentType: string, prompt: string): Phase | undefined {
  const normalizedAgent = agentType.toLowerCase();
  
  // Direct agent type mapping
  const agentPhaseMap: Record<string, Phase> = {
    "brainstorm-agent": "brainstorm",
    "specify-agent": "specify",
    "clarify-agent": "clarify",
    "architecture-agent": "architecture",
    // Implementation agents
    "code-implementer-agent": "execute",
    "java-test-agent": "execute",
    "ts-test-agent": "execute",
    "frontend-agent": "execute",
    "security-agent": "execute",
    "k8s-agent": "execute",
    "keycloak-agent": "execute",
    "dotfiles-agent": "execute",
    // Review agents
    "spec-check-invoker": "execute",
    "review-invoker": "execute",
    "task-reviewer": "execute",
  };
  
  if (agentPhaseMap[normalizedAgent]) {
    return agentPhaseMap[normalizedAgent];
  }
  
  // Fallback: try to detect phase from prompt content
  const promptLower = prompt.toLowerCase();
  if (/brainstorm|explore.*intent|refine.*idea/i.test(promptLower)) {
    return "brainstorm";
  }
  if (/specify|specification|requirements|spec\.md/i.test(promptLower)) {
    return "specify";
  }
  if (/clarify|resolve.*markers|needs clarification/i.test(promptLower)) {
    return "clarify";
  }
  if (/architecture|design|plan\.md/i.test(promptLower)) {
    return "architecture";
  }
  
  return undefined;
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
export function isValidTransition(
  from: Phase,
  to: Phase,
  _skippedPhases: Phase[] = []
): boolean {
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
export function checkArtifactPrerequisites(
  targetPhase: Phase,
  taskGraph: TaskGraph,
  projectDir: string
): ArtifactPrerequisiteResult {
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
    } catch {
      // If we can't check, allow and let later steps fail
      console.warn(
        `[task-planner] Could not verify artifact exists: ${artifact}`
      );
    }
  }

  return { valid: true };
}

/**
 * Get prerequisite phases and their artifact types for a target phase.
 */
function getPhasePrerequisites(
  phase: Phase
): Array<{ phase: Phase; type: "spec" | "plan" }> {
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
export function isPhaseExempt(skillName: string): boolean {
  return PHASE_EXEMPT_SKILLS.some(
    (exempt) => exempt.toLowerCase() === skillName
  );
}

/**
 * Get the phase for a skill name.
 *
 * @param skillName - Skill name (case-insensitive)
 * @returns Phase or undefined if not found
 */
export function getPhaseForSkill(skillName: string): Phase | undefined {
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
export function isValidArtifactPath(path: string): boolean {
  // Check against allowed patterns
  const isAllowed = ALLOWED_ARTIFACT_PATHS.some((pattern) => pattern.test(path));

  // Check for legacy .claude/ paths and warn
  if (path.startsWith(".claude/")) {
    console.warn(ERRORS.LEGACY_PATH_WARNING(path));
  }

  return isAllowed;
}
