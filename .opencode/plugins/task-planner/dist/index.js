/**
 * Task Planner Plugin for OpenCode
 *
 * This plugin enforces structured task execution following the task-planner
 * workflow: brainstorm -> specify -> clarify -> architecture -> decompose -> execute
 *
 * It provides:
 * - Blocking of direct Edit/Write during orchestration (Phase 1)
 * - Protection of state files from Bash writes (Phase 1)
 * - Phase transition validation (Phase 2)
 * - Task execution validation (wave order, dependencies, review gate) (Phase 3)
 * - Task status updates and test evidence capture (Phase 3)
 * - New test verification (Phase 3)
 * - Review findings capture (CRITICAL/ADVISORY markers) (Phase 4)
 * - Spec-check parsing (Phase 4)
 *
 * Converted from Claude Code hooks to OpenCode plugin system.
 */
import { StateManager } from "./utils/state-manager.js";
import { blockDirectEdits } from "./hooks/block-direct-edits.js";
import { guardStateFile } from "./hooks/guard-state-file.js";
import { validatePhaseOrder } from "./hooks/validate-phase-order.js";
import { advancePhase } from "./hooks/advance-phase.js";
import { validateTaskExecution } from "./hooks/validate-task-execution.js";
import { updateTaskStatus } from "./hooks/update-task-status.js";
import { verifyNewTests } from "./hooks/verify-new-tests.js";
import { storeReviewFindings, isReviewContent, } from "./hooks/store-review-findings.js";
import { parseSpecCheck, isSpecCheckContent, } from "./hooks/parse-spec-check.js";
// Wave gate functions are used by the /wave-gate skill, not plugin hooks
// Re-exported for skill access
export { completeWaveGate, isWaveImplementationComplete, } from "./hooks/complete-wave-gate.js";
import { PhaseAdvancementDebouncer, MessageBuffer, } from "./utils/debounce.js";
import { extractTaskIdFromArgs } from "./utils/task-id-extractor.js";
// ============================================================================
// Plugin State
// ============================================================================
/**
 * Global state manager instance (created per plugin instantiation).
 */
let stateManager = null;
/**
 * Phase advancement debouncer for session.idle events.
 */
let phaseDebouncer = null;
/**
 * Message buffer to track recent messages for session.idle.
 */
let messageBuffer = null;
/**
 * Project directory for the current plugin instance.
 */
let projectDir = "";
/**
 * Cached task graph to avoid repeated disk reads.
 * Invalidated on file.edited for state files.
 */
let cachedTaskGraph = null;
let cacheValid = false;
/**
 * Currently executing task context (set when Task tool is invoked).
 * Used to track agent completion and update task status.
 */
let currentTaskContext = null;
/**
 * Set of session IDs that have active task executions.
 * Used to allow subagent edits during orchestration.
 */
let activeTaskSessions = new Set();
/**
 * Shell instance for running git commands.
 * Set during plugin initialization.
 */
let shell = null;
// ============================================================================
// Git Diff Helper
// ============================================================================
/**
 * Get git diff for the specified files.
 * Returns the diff content showing added/removed lines.
 * Handles both tracked (modified) and untracked (new) files.
 */
async function getGitDiff(files) {
    if (!shell || files.length === 0) {
        return "";
    }
    const diffs = [];
    try {
        for (const file of files) {
            // Check if file is tracked or untracked
            const isTracked = await shell `git ls-files --error-unmatch ${file}`
                .quiet()
                .nothrow();
            if (isTracked.exitCode === 0) {
                // File is tracked - get normal diff
                const diff = await shell `git diff HEAD -- ${file}`.quiet().nothrow().text();
                if (diff) {
                    diffs.push(diff);
                }
            }
            else {
                // File is untracked (new) - simulate diff by prefixing all lines with +
                try {
                    const content = await Bun.file(file).text();
                    const lines = content.split("\n");
                    const simulatedDiff = [
                        `diff --git a/${file} b/${file}`,
                        `new file mode 100644`,
                        `--- /dev/null`,
                        `+++ b/${file}`,
                        `@@ -0,0 +1,${lines.length} @@`,
                        ...lines.map((line) => `+${line}`),
                    ].join("\n");
                    diffs.push(simulatedDiff);
                }
                catch {
                    // File might not exist, skip
                    console.log(`[task-planner] Could not read untracked file: ${file}`);
                }
            }
        }
        return diffs.join("\n");
    }
    catch (error) {
        console.error("[task-planner] Git diff error:", error);
        return "";
    }
}
// ============================================================================
// Plugin Factory
// ============================================================================
/**
 * Task Planner Plugin factory function.
 *
 * This is the main entry point that OpenCode calls to initialize the plugin.
 * Uses the official @opencode-ai/plugin types.
 */
export const TaskPlannerPlugin = async ({ directory, worktree, $, }) => {
    console.log("[task-planner] Initializing plugin for:", directory);
    console.log("[task-planner] Worktree:", worktree);
    // Store project directory for use in hooks
    projectDir = directory;
    // Store shell for git commands
    shell = $;
    // Create state manager for this project
    stateManager = new StateManager(directory);
    // Initialize Phase 2 utilities
    phaseDebouncer = new PhaseAdvancementDebouncer();
    messageBuffer = new MessageBuffer();
    return {
        /**
         * Pre-tool execution hook.
         *
         * Checks all tool invocations and blocks those that violate
         * the orchestration rules.
         *
         * OpenCode signature: (input, output) => Promise<void>
         * - input: { tool, sessionID, callID }
         * - output: { args } (mutable)
         */
        "tool.execute.before": async (input, output) => {
            const taskGraph = await getTaskGraph();
            // Convert to legacy format for existing hooks
            const legacyInput = {
                tool: input.tool,
                args: output.args,
            };
            // Check 1: Block direct edits during orchestration (Phase 1)
            // BUT allow edits when:
            // - A task is currently executing (currentTaskContext is set), OR
            // - This session is part of an active task execution, OR  
            // - Any task sessions are active (subagents share plugin but different session), OR
            // - Tasks are marked as executing in persisted state (subagents in separate processes)
            const isTaskSession = activeTaskSessions.size > 0 ||
                currentTaskContext !== null ||
                (taskGraph?.executing_tasks?.length ?? 0) > 0;
            if (!isTaskSession) {
                blockDirectEdits(legacyInput, taskGraph);
            }
            // Check 2: Guard state files from Bash writes (Phase 1)
            guardStateFile(legacyInput, taskGraph);
            // Check 3: Validate phase order for skill invocations (Phase 2)
            validatePhaseOrder(legacyInput, taskGraph, projectDir);
            // Check 4: Validate task execution (wave order, dependencies, review gate) (Phase 3)
            if (input.tool.toLowerCase() === "task") {
                const taskInput = {
                    tool: input.tool,
                    args: output.args,
                };
                validateTaskExecution(taskInput, taskGraph);
                // Track current task for status updates on completion
                // BUT skip for review/spec-check agents - they don't update task status
                const agentType = taskInput.args.subagent_type?.toLowerCase() ?? "";
                const isReviewAgent = agentType.includes("review") ||
                    agentType.includes("spec-check") ||
                    agentType === "general"; // general agents used for verification don't track
                const taskId = extractTaskIdFromArgs(taskInput.args);
                if (taskId && stateManager && !isReviewAgent) {
                    currentTaskContext = {
                        sessionId: input.sessionID,
                        taskId,
                        agentType: taskInput.args.subagent_type,
                        transcript: "", // Will be populated from message buffer
                    };
                    activeTaskSessions.add(input.sessionID);
                    // Mark task as executing in state
                    await stateManager.markTaskExecuting(taskId);
                    await stateManager.setTaskStatus(taskId, "in_progress");
                    invalidateCache();
                    console.log(`[task-planner] Task ${taskId} execution started`);
                }
                else if (taskId && isReviewAgent) {
                    // Still track session for edit blocking, but don't update task status
                    activeTaskSessions.add(input.sessionID);
                    console.log(`[task-planner] Review/verification agent for ${taskId} (no status update)`);
                }
            }
        },
        /**
         * Post-tool execution hook.
         *
         * Captures Task tool output and updates task status immediately.
         * This is more reliable than session.idle for test evidence extraction
         * because we have direct access to the agent's output.
         */
        "tool.execute.after": async (input, output) => {
            // Only process Task tool completions
            if (input.tool.toLowerCase() !== "task")
                return;
            if (!stateManager)
                return;
            const taskGraph = await getTaskGraph();
            if (!taskGraph)
                return;
            const taskOutput = output.output ?? "";
            // Phase 4: Check Task output for review/spec-check content
            // This handles subagent outputs that don't trigger message.updated events
            try {
                // Check for review findings in Task output
                if (isReviewContent(taskOutput)) {
                    console.log("[task-planner] Review content detected in Task output");
                    const reviewResult = await storeReviewFindings(taskOutput, taskGraph, stateManager, undefined // Let the parser extract task ID from content
                    );
                    if (reviewResult) {
                        invalidateCache();
                        console.log(`[task-planner] Review findings stored for ${reviewResult.taskId}: ${reviewResult.verdict}`);
                    }
                }
                // Check for spec-check findings in Task output
                if (isSpecCheckContent(taskOutput)) {
                    console.log("[task-planner] Spec-check content detected in Task output");
                    const specResult = await parseSpecCheck(taskOutput, taskGraph, stateManager);
                    if (specResult) {
                        invalidateCache();
                        console.log(`[task-planner] Spec-check results: ${specResult.verdict} (${specResult.criticalCount} critical)`);
                    }
                }
            }
            catch (error) {
                console.error("[task-planner] Review/spec-check parsing error:", error);
            }
            // Phase 3: Update task status for implementation agents
            // Only process if we have a tracked task context (implementation agents only)
            if (!currentTaskContext)
                return;
            if (taskGraph.current_phase !== "execute")
                return;
            console.log(`[task-planner] Task tool completed for ${currentTaskContext.taskId}`);
            try {
                // Build completion context from Task output
                const completionContext = {
                    ...currentTaskContext,
                    transcript: taskOutput, // Use Task tool's output directly
                    filesModified: stateManager.getFilesModified(),
                };
                // Update task status with test evidence
                const statusResult = await updateTaskStatus(completionContext, taskGraph, stateManager);
                if (statusResult) {
                    invalidateCache();
                    console.log(`[task-planner] Task ${statusResult.taskId} status updated via tool.execute.after`);
                    // Verify new tests were written (if required)
                    // Get git diff for modified files to detect new test methods
                    const testFiles = (completionContext.filesModified ?? []).filter((f) => f.includes(".test.") || f.includes(".spec.") || f.includes("/test/"));
                    const diffContent = await getGitDiff(testFiles);
                    await verifyNewTests(completionContext, taskGraph, stateManager, diffContent);
                    if (statusResult.waveComplete) {
                        console.log(`[task-planner] Wave ${taskGraph.current_wave} implementation complete!`);
                        console.log("[task-planner] Run /wave-gate to proceed");
                        await stateManager.updateWaveGate(taskGraph.current_wave, {
                            impl_complete: true,
                        });
                        invalidateCache();
                    }
                }
                // Remove from active sessions before clearing context
                activeTaskSessions.delete(currentTaskContext.sessionId);
                // Clear task context after processing
                currentTaskContext = null;
                stateManager.clearFilesModified();
            }
            catch (error) {
                console.error("[task-planner] Task status update error:", error);
            }
        },
        /**
         * Event handler for OpenCode events.
         *
         * Handles session.idle and file.edited events.
         */
        event: async ({ event }) => {
            // Handle session.idle event
            if (event.type === "session.idle") {
                const taskGraph = await getTaskGraph();
                if (!taskGraph)
                    return;
                if (!stateManager || !phaseDebouncer || !messageBuffer)
                    return;
                // Get last assistant message for detection
                const lastMessage = messageBuffer.getLastAssistantMessage();
                if (!lastMessage)
                    return;
                // Debounce rapid idle events
                if (!phaseDebouncer.shouldProcess(lastMessage)) {
                    return;
                }
                console.log("[task-planner] Session idle detected");
                // Phase 2: Check for phase completion and advance
                try {
                    const phaseResult = await advancePhase(lastMessage, taskGraph, stateManager, projectDir);
                    if (phaseResult) {
                        invalidateCache();
                        console.log(`[task-planner] Phase advanced: ${phaseResult.completedPhase} -> ${phaseResult.newPhase}`);
                    }
                }
                catch (error) {
                    console.error("[task-planner] Phase advancement error:", error);
                }
                // Phase 3: Update task status if a task was executing
                if (currentTaskContext && taskGraph.current_phase === "execute") {
                    try {
                        // Build completion context from buffered messages
                        const completionContext = {
                            ...currentTaskContext,
                            transcript: messageBuffer.getFullTranscript(),
                            filesModified: stateManager.getFilesModified(),
                        };
                        // Update task status with test evidence
                        const statusResult = await updateTaskStatus(completionContext, taskGraph, stateManager);
                        if (statusResult) {
                            invalidateCache();
                            console.log(`[task-planner] Task ${statusResult.taskId} status updated`);
                            // Verify new tests were written (if required)
                            // Get git diff for modified files to detect new test methods
                            const testFiles = (completionContext.filesModified ?? []).filter((f) => f.includes(".test.") || f.includes(".spec.") || f.includes("/test/"));
                            const diffContent = await getGitDiff(testFiles);
                            await verifyNewTests(completionContext, taskGraph, stateManager, diffContent);
                            if (statusResult.waveComplete) {
                                console.log(`[task-planner] Wave ${taskGraph.current_wave} implementation complete!`);
                                console.log("[task-planner] Run /wave-gate to proceed");
                                // Mark wave implementation as complete in wave_gates
                                await stateManager.updateWaveGate(taskGraph.current_wave, {
                                    impl_complete: true,
                                });
                                invalidateCache();
                            }
                        }
                        // Remove from active sessions before clearing context
                        if (currentTaskContext?.sessionId) {
                            activeTaskSessions.delete(currentTaskContext.sessionId);
                        }
                        // Clear task context after processing
                        currentTaskContext = null;
                        stateManager.clearFilesModified();
                    }
                    catch (error) {
                        console.error("[task-planner] Task status update error:", error);
                    }
                }
                phaseDebouncer.markProcessed();
            }
            // Handle file.edited event
            if (event.type === "file.edited") {
                const fileEvent = event;
                const path = fileEvent.properties?.file;
                if (!stateManager || !path)
                    return;
                // Track the edit
                stateManager.trackFileEdit(path);
                // Invalidate cache if state file was edited externally
                if (path.includes(".opencode/state/")) {
                    cacheValid = false;
                }
                console.log("[task-planner] File edited:", path);
            }
            // Handle message.updated event
            if (event.type === "message.updated") {
                const msgEvent = event;
                const role = msgEvent.properties?.role;
                const content = msgEvent.properties?.content;
                // Only process assistant messages
                if (role !== "assistant" || !content)
                    return;
                // Buffer the message for session.idle fallback
                if (messageBuffer) {
                    messageBuffer.push(role, content);
                }
                const taskGraph = await getTaskGraph();
                if (!taskGraph)
                    return;
                if (!stateManager)
                    return;
                // Phase 2: Check for phase completion and advance
                try {
                    const phaseResult = await advancePhase(content, taskGraph, stateManager, projectDir);
                    if (phaseResult) {
                        invalidateCache();
                        console.log(`[task-planner] Phase advanced: ${phaseResult.completedPhase} -> ${phaseResult.newPhase}`);
                    }
                }
                catch (error) {
                    console.error("[task-planner] Phase advancement error:", error);
                }
                // Phase 4: Check for review findings
                if (isReviewContent(content)) {
                    try {
                        const reviewResult = await storeReviewFindings(content, taskGraph, stateManager, currentTaskContext?.taskId);
                        if (reviewResult) {
                            invalidateCache();
                            console.log(`[task-planner] Review findings stored for ${reviewResult.taskId}: ${reviewResult.verdict}`);
                        }
                    }
                    catch (error) {
                        console.error("[task-planner] Review findings error:", error);
                    }
                }
                // Phase 4: Check for spec-check findings
                if (isSpecCheckContent(content)) {
                    try {
                        const specResult = await parseSpecCheck(content, taskGraph, stateManager);
                        if (specResult) {
                            invalidateCache();
                            console.log(`[task-planner] Spec-check results: ${specResult.verdict} (${specResult.criticalCount} critical)`);
                        }
                    }
                    catch (error) {
                        console.error("[task-planner] Spec-check parsing error:", error);
                    }
                }
            }
        },
    };
};
// ============================================================================
// Helper Functions
// ============================================================================
/**
 * Get the current task graph, using cache when valid.
 *
 * IMPORTANT: Always checks file existence before returning cached data,
 * because external processes (like manual `rm`) can delete the file
 * without triggering a file.edited event.
 */
async function getTaskGraph() {
    if (!stateManager) {
        return null;
    }
    // Always check file existence - cache can be stale if file deleted externally
    const hasGraph = await stateManager.hasActiveTaskGraph();
    if (!hasGraph) {
        cachedTaskGraph = null;
        cacheValid = false;
        return null;
    }
    if (cacheValid && cachedTaskGraph !== undefined) {
        return cachedTaskGraph;
    }
    cachedTaskGraph = await stateManager.load();
    cacheValid = true;
    return cachedTaskGraph;
}
/**
 * Invalidate the task graph cache.
 * Call this after any state modifications.
 */
export function invalidateCache() {
    cacheValid = false;
    cachedTaskGraph = null;
}
/**
 * Get the state manager instance (for external access if needed).
 */
export function getStateManager() {
    return stateManager;
}
/**
 * Get the current task context (for testing/debugging).
 */
export function getCurrentTaskContext() {
    return currentTaskContext;
}
// ============================================================================
// Default Export
// ============================================================================
export default TaskPlannerPlugin;
//# sourceMappingURL=index.js.map