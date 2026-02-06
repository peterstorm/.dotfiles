/**
 * Store Review Findings Hook
 *
 * Parses review agent output for CRITICAL and ADVISORY markers.
 * Stores findings in the task graph for wave gate verification.
 *
 * CRITICAL findings block wave advancement.
 * ADVISORY findings are logged but don't block.
 *
 * This hook is called from message.updated when review content is detected.
 */

import type { TaskGraph, Task } from "../types";
import { StateManager } from "../utils/state-manager";
import { extractTaskId } from "../utils/task-id-extractor";
import {
  CRITICAL_FINDING_PATTERN,
  ADVISORY_FINDING_PATTERN,
  TASK_REVIEW_AGENTS,
} from "../constants";

// ============================================================================
// Types
// ============================================================================

/**
 * Parsed review findings from agent output.
 */
export interface ReviewFindings {
  /** Task ID the review is for */
  taskId: string;

  /** Critical findings that block wave advancement */
  criticalFindings: string[];

  /** Advisory findings (non-blocking) */
  advisoryFindings: string[];

  /** Overall review verdict */
  verdict: "passed" | "blocked";
}

// ============================================================================
// Main Function
// ============================================================================

/**
 * Parse and store review findings from message content.
 *
 * Called when a message is detected to contain review output
 * (CRITICAL/ADVISORY markers or review agent completion signals).
 *
 * @param content - Message content to parse
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @param taskId - Optional explicit task ID (if known from context)
 * @returns Parsed findings, or null if no review content detected
 */
export async function storeReviewFindings(
  content: string,
  taskGraph: TaskGraph,
  stateManager: StateManager,
  taskId?: string
): Promise<ReviewFindings | null> {
  // Extract findings from content
  const criticalFindings = extractCriticalFindings(content);
  const advisoryFindings = extractAdvisoryFindings(content);

  // If no findings, check if this is a review completion without issues
  if (criticalFindings.length === 0 && advisoryFindings.length === 0) {
    // Check for review pass signals
    if (!isReviewPassMessage(content)) {
      return null; // Not a review message
    }
  }

  // Determine task ID
  const resolvedTaskId = taskId ?? extractTaskId(content);

  if (!resolvedTaskId) {
    console.log("[task-planner] Review findings detected but no task ID found");
    return null;
  }

  // Find the task
  const task = taskGraph.tasks.find((t) => t.id === resolvedTaskId);

  if (!task) {
    console.log(`[task-planner] Task ${resolvedTaskId} not found for review findings`);
    return null;
  }

  // Determine verdict
  const verdict = criticalFindings.length > 0 ? "blocked" : "passed";

  // Update task with findings
  await stateManager.updateTask(resolvedTaskId, {
    review_status: verdict,
    critical_findings: criticalFindings,
    advisory_findings: advisoryFindings,
  });

  // Log results
  console.log(`[task-planner] Review findings for ${resolvedTaskId}:`);
  console.log(`  Verdict: ${verdict.toUpperCase()}`);

  if (criticalFindings.length > 0) {
    console.log(`  CRITICAL (${criticalFindings.length}):`);
    for (const finding of criticalFindings) {
      console.log(`    🚨 ${finding}`);
    }
  }

  if (advisoryFindings.length > 0) {
    console.log(`  ADVISORY (${advisoryFindings.length}):`);
    for (const finding of advisoryFindings) {
      console.log(`    💡 ${finding}`);
    }
  }

  if (criticalFindings.length === 0 && advisoryFindings.length === 0) {
    console.log("  No issues found - review passed");
  }

  return {
    taskId: resolvedTaskId,
    criticalFindings,
    advisoryFindings,
    verdict,
  };
}

// ============================================================================
// Extraction Functions
// ============================================================================

/**
 * Extract CRITICAL findings from content.
 *
 * Matches patterns like:
 * - CRITICAL: Description of issue
 * - 🚨 CRITICAL: Description of issue
 */
export function extractCriticalFindings(content: string): string[] {
  const findings: string[] = [];

  // Reset regex state (global flag)
  CRITICAL_FINDING_PATTERN.lastIndex = 0;

  const matches = content.matchAll(CRITICAL_FINDING_PATTERN);

  for (const match of matches) {
    if (match[1]) {
      findings.push(match[1].trim());
    }
  }

  return findings;
}

/**
 * Extract ADVISORY findings from content.
 *
 * Matches patterns like:
 * - ADVISORY: Suggestion for improvement
 * - 💡 ADVISORY: Suggestion for improvement
 */
export function extractAdvisoryFindings(content: string): string[] {
  const findings: string[] = [];

  // Reset regex state (global flag)
  ADVISORY_FINDING_PATTERN.lastIndex = 0;

  const matches = content.matchAll(ADVISORY_FINDING_PATTERN);

  for (const match of matches) {
    if (match[1]) {
      findings.push(match[1].trim());
    }
  }

  return findings;
}

// ============================================================================
// Detection Functions
// ============================================================================

/**
 * Check if content indicates a review was completed.
 *
 * Used to detect review completions even when no findings are present.
 */
export function isReviewContent(content: string): boolean {
  // Check for finding markers
  if (CRITICAL_FINDING_PATTERN.test(content)) return true;
  if (ADVISORY_FINDING_PATTERN.test(content)) return true;

  // Check for review completion signals
  if (isReviewPassMessage(content)) return true;

  // Check for review section headers
  const reviewPatterns = [
    /##?\s*(?:Code\s+)?Review/i,
    /##?\s*Review\s+(?:Summary|Findings|Results)/i,
    /Review\s+(?:complete|finished|done)/i,
    /REVIEW_TASK:/i,
    /REVIEW_VERDICT:/i,
    /REVIEW_CRITICAL_COUNT:/i,
  ];

  return reviewPatterns.some((pattern) => pattern.test(content));
}

/**
 * Check if content indicates a passing review.
 *
 * Used to mark tasks as reviewed even when no issues are found.
 */
export function isReviewPassMessage(content: string): boolean {
  const passPatterns = [
    /review\s+(?:passed|complete|approved)/i,
    /no\s+(?:critical\s+)?(?:issues|findings|problems)\s+found/i,
    /LGTM/i,
    /looks\s+good\s+to\s+me/i,
    /code\s+(?:looks\s+)?good/i,
    /approved\s+(?:for\s+merge|to\s+proceed)/i,
    /REVIEW_VERDICT:\s*PASSED/i,
    /REVIEW_CRITICAL_COUNT:\s*0/i,
  ];

  return passPatterns.some((pattern) => pattern.test(content));
}

/**
 * Check if an agent type is a review agent.
 */
export function isReviewAgent(agentType?: string): boolean {
  if (!agentType) return false;

  // Check explicit review agent types
  if (TASK_REVIEW_AGENTS.includes(agentType)) {
    return true;
  }

  // Check for review in agent name
  const lowerType = agentType.toLowerCase();
  return lowerType.includes("review") || lowerType.includes("reviewer");
}

// ============================================================================
// Aggregation Functions
// ============================================================================

/**
 * Count total critical findings across all tasks in a wave.
 */
export function countWaveCriticalFindings(
  taskGraph: TaskGraph,
  wave: number
): number {
  const waveTasks = taskGraph.tasks.filter((t) => t.wave === wave);

  return waveTasks.reduce((total, task) => {
    return total + (task.critical_findings?.length ?? 0);
  }, 0);
}

/**
 * Get all tasks with critical findings in a wave.
 */
export function getBlockedTasks(
  taskGraph: TaskGraph,
  wave: number
): Task[] {
  return taskGraph.tasks.filter(
    (t) =>
      t.wave === wave &&
      t.critical_findings &&
      t.critical_findings.length > 0
  );
}

/**
 * Check if all tasks in a wave have been reviewed.
 */
export function areAllTasksReviewed(
  taskGraph: TaskGraph,
  wave: number
): boolean {
  const waveTasks = taskGraph.tasks.filter((t) => t.wave === wave);

  return waveTasks.every(
    (t) => t.review_status === "passed" || t.review_status === "blocked"
  );
}
