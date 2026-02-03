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
export declare function parseSpecCheck(content: string, taskGraph: TaskGraph, stateManager: StateManager): Promise<SpecCheckResults | null>;
/**
 * Extract spec-check findings from content.
 *
 * Matches patterns like:
 * - [CRITICAL] Description of spec drift
 * - [HIGH] Missing implementation for FR-001
 * - [MEDIUM] Suggested improvement
 */
export declare function extractSpecCheckFindings(content: string): SpecCheckFinding[];
/**
 * Check if content is from spec-check agent.
 */
export declare function isSpecCheckContent(content: string): boolean;
/**
 * Determine the overall verdict from content and findings.
 */
export declare function determineVerdict(content: string, criticalCount: number): ReviewVerdict;
/**
 * Check if spec-check passed for a wave.
 */
export declare function isSpecCheckPassed(taskGraph: TaskGraph, wave: number): boolean;
/**
 * Get spec-check summary for logging.
 */
export declare function getSpecCheckSummary(specCheck: SpecCheck): string;
//# sourceMappingURL=parse-spec-check.d.ts.map