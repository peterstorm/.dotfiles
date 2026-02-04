/**
 * Parse Spec Check Hook
 *
 * Parses spec-check agent output for alignment findings.
 * Stores results in task graph for wave gate verification.
 *
 * Spec-check validates that implementation aligns with specification.
 * Critical findings indicate spec drift that must be fixed.
 *
 * This hook is called from message.updated when spec-check content is detected.
 */

import type { TaskGraph, SpecCheck, ReviewVerdict } from "../types.js";
import { StateManager } from "../utils/state-manager.js";
import { SPEC_CHECK_FINDING_PATTERN } from "../constants.js";

// ============================================================================
// Types
// ============================================================================

/**
 * Parsed spec-check finding with severity.
 */
export interface SpecCheckFinding {
  /** Severity level: CRITICAL, HIGH, MEDIUM, LOW */
  severity: "CRITICAL" | "HIGH" | "MEDIUM" | "LOW";

  /** Description of the finding */
  description: string;
}

/**
 * Parsed spec-check results.
 */
export interface SpecCheckResults {
  /** Wave number the check was run for */
  wave: number;

  /** All findings organized by severity */
  findings: SpecCheckFinding[];

  /** Count of critical findings */
  criticalCount: number;

  /** Count of high priority findings */
  highCount: number;

  /** Overall verdict */
  verdict: ReviewVerdict;
}

// ============================================================================
// Main Function
// ============================================================================

/**
 * Parse and store spec-check findings from message content.
 *
 * Called when a message is detected to contain spec-check output.
 *
 * @param content - Message content to parse
 * @param taskGraph - Current task graph state
 * @param stateManager - State manager for persisting updates
 * @returns Parsed results, or null if no spec-check content detected
 */
export async function parseSpecCheck(
  content: string,
  taskGraph: TaskGraph,
  stateManager: StateManager
): Promise<SpecCheckResults | null> {
  // Check if this is spec-check content
  if (!isSpecCheckContent(content)) {
    return null;
  }

  // Extract findings
  const findings = extractSpecCheckFindings(content);

  // Categorize by severity
  const criticalFindings = findings.filter((f) => f.severity === "CRITICAL");
  const highFindings = findings.filter((f) => f.severity === "HIGH");
  const mediumFindings = findings.filter((f) => f.severity === "MEDIUM");

  // Determine verdict
  const verdict = determineVerdict(content, criticalFindings.length);

  // Create spec-check record
  const specCheck: SpecCheck = {
    wave: taskGraph.current_wave,
    run_at: new Date().toISOString(),
    critical_count: criticalFindings.length,
    high_count: highFindings.length,
    critical_findings: criticalFindings.map((f) => f.description),
    high_findings: highFindings.map((f) => f.description),
    medium_findings: mediumFindings.map((f) => f.description),
    verdict,
  };

  // Update task graph with spec-check results
  const updatedGraph = await stateManager.load();
  if (updatedGraph) {
    updatedGraph.spec_check = specCheck;
    await stateManager.save(updatedGraph);
  }

  // Log results
  console.log(`[task-planner] Spec-check results for wave ${taskGraph.current_wave}:`);
  console.log(`  Verdict: ${verdict}`);
  console.log(`  Critical: ${criticalFindings.length}`);
  console.log(`  High: ${highFindings.length}`);
  console.log(`  Medium: ${mediumFindings.length}`);

  if (criticalFindings.length > 0) {
    console.log("  Critical findings:");
    for (const finding of criticalFindings) {
      console.log(`    🚨 ${finding.description}`);
    }
  }

  return {
    wave: taskGraph.current_wave,
    findings,
    criticalCount: criticalFindings.length,
    highCount: highFindings.length,
    verdict,
  };
}

// ============================================================================
// Extraction Functions
// ============================================================================

/**
 * Extract spec-check findings from content.
 *
 * Matches patterns like:
 * - [CRITICAL] Description of spec drift
 * - [HIGH] Missing implementation for FR-001
 * - [MEDIUM] Suggested improvement
 */
export function extractSpecCheckFindings(content: string): SpecCheckFinding[] {
  const findings: SpecCheckFinding[] = [];

  // Reset regex state (global flag)
  SPEC_CHECK_FINDING_PATTERN.lastIndex = 0;

  const matches = content.matchAll(SPEC_CHECK_FINDING_PATTERN);

  for (const match of matches) {
    const severityStr = match[1]?.toUpperCase();
    const description = match[2]?.trim();

    if (severityStr && description) {
      // Validate severity
      if (isValidSeverity(severityStr)) {
        findings.push({
          severity: severityStr as SpecCheckFinding["severity"],
          description,
        });
      }
    }
  }

  return findings;
}

/**
 * Check if a severity string is valid.
 */
function isValidSeverity(severity: string): boolean {
  return ["CRITICAL", "HIGH", "MEDIUM", "LOW"].includes(severity);
}

// ============================================================================
// Detection Functions
// ============================================================================

/**
 * Check if content is from spec-check agent.
 */
export function isSpecCheckContent(content: string): boolean {
  // Check for spec-check specific patterns
  const specCheckPatterns = [
    /spec(?:ification)?\s*(?:alignment|check|drift)/i,
    /##?\s*Spec(?:ification)?\s*(?:Alignment|Check|Drift)/i,
    /\[(?:CRITICAL|HIGH|MEDIUM|LOW)\]/,
    /alignment\s+(?:analysis|check|verification)/i,
    /spec-check\s+(?:results|findings|complete)/i,
    /verifying\s+(?:spec(?:ification)?\s+)?alignment/i,
    /SPEC_CHECK_WAVE:/i,
    /SPEC_CHECK_VERDICT:/i,
    /SPEC_CHECK_CRITICAL_COUNT:/i,
  ];

  return specCheckPatterns.some((pattern) => pattern.test(content));
}

/**
 * Determine the overall verdict from content and findings.
 */
export function determineVerdict(
  content: string,
  criticalCount: number
): ReviewVerdict {
  // Explicit verdict in content takes precedence
  // Match both "verdict: PASSED" and "SPEC_CHECK_VERDICT: PASSED"
  if (/(?:SPEC_CHECK_)?verdict[:\s]+PASSED/i.test(content)) {
    return "PASSED";
  }

  if (/(?:SPEC_CHECK_)?verdict[:\s]+BLOCKED/i.test(content)) {
    return "BLOCKED";
  }

  // Otherwise, based on critical count
  if (criticalCount > 0) {
    return "BLOCKED";
  }

  // Check for pass signals
  if (/(?:all\s+)?(?:checks?\s+)?pass(?:ed)?/i.test(content)) {
    return "PASSED";
  }

  if (/no\s+(?:spec\s+)?drift\s+(?:detected|found)/i.test(content)) {
    return "PASSED";
  }

  if (/implementation\s+(?:matches|aligns\s+with)\s+spec/i.test(content)) {
    return "PASSED";
  }

  // Default based on findings
  return criticalCount === 0 ? "PASSED" : "BLOCKED";
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Check if spec-check passed for a wave.
 */
export function isSpecCheckPassed(taskGraph: TaskGraph, wave: number): boolean {
  const specCheck = taskGraph.spec_check;

  if (!specCheck) {
    return true; // No spec-check run = pass (optional check)
  }

  // Warn if spec-check was for different wave
  if (specCheck.wave !== wave) {
    console.warn(
      `[task-planner] Spec-check was run for wave ${specCheck.wave}, not ${wave}`
    );
    return true; // Consider passed if for different wave
  }

  return specCheck.verdict === "PASSED";
}

/**
 * Get spec-check summary for logging.
 */
export function getSpecCheckSummary(specCheck: SpecCheck): string {
  if (specCheck.verdict === "PASSED") {
    return `✅ Spec alignment verified (wave ${specCheck.wave})`;
  }

  return `❌ Spec drift detected: ${specCheck.critical_count} critical, ${specCheck.high_count} high (wave ${specCheck.wave})`;
}
