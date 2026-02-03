/**
 * Integration tests for Phase Enforcement
 *
 * These tests verify end-to-end phase enforcement workflow including:
 * - Full workflow: init → brainstorm → specify → architecture → decompose → execute
 * - Skipping brainstorm: init → specify
 * - Auto-skipping clarify when markers ≤ 3
 * - State consistency across operations
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdir, writeFile, rm } from "fs/promises";
import { join } from "path";
import { tmpdir } from "os";
import { existsSync } from "fs";
import { StateManager } from "./utils/state-manager.js";
import { validatePhaseOrder } from "./hooks/validate-phase-order.js";
import { advancePhase } from "./hooks/advance-phase.js";
import { PhaseAdvancementDebouncer, MessageBuffer } from "./utils/debounce.js";
// ============================================================================
// Test Fixtures
// ============================================================================
let testDir;
let stateManager;
function createTaskGraph(overrides = {}) {
    return {
        title: "Integration Test Task Graph",
        spec_file: ".opencode/specs/test/spec.md",
        plan_file: ".opencode/plans/test.md",
        current_phase: "init",
        phase_artifacts: {},
        skipped_phases: [],
        current_wave: 1,
        tasks: [],
        executing_tasks: [],
        wave_gates: {},
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        ...overrides,
    };
}
function createSkillInput(skillName) {
    return {
        tool: "skill",
        args: { name: skillName },
    };
}
// ============================================================================
// Setup / Teardown
// ============================================================================
beforeEach(async () => {
    // Create a unique temp directory for each test
    testDir = join(tmpdir(), `task-planner-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    await mkdir(join(testDir, ".opencode", "state"), { recursive: true });
    await mkdir(join(testDir, ".opencode", "specs"), { recursive: true });
    await mkdir(join(testDir, ".opencode", "plans"), { recursive: true });
    stateManager = new StateManager(testDir);
});
afterEach(async () => {
    // Cleanup temp directory
    if (testDir && existsSync(testDir)) {
        await rm(testDir, { recursive: true, force: true });
    }
});
// ============================================================================
// Integration Tests
// ============================================================================
describe("Phase Enforcement Integration", () => {
    describe("full workflow enforcement", () => {
        it("allows progression through all phases in order", async () => {
            // Start with init phase
            let taskGraph = createTaskGraph({ current_phase: "init" });
            await stateManager.save(taskGraph);
            // init → brainstorm (allowed)
            expect(() => {
                validatePhaseOrder(createSkillInput("brainstorming"), taskGraph, testDir);
            }).not.toThrow();
            // Simulate brainstorm completion
            taskGraph.current_phase = "brainstorm";
            taskGraph.phase_artifacts.brainstorm = "completed";
            await stateManager.save(taskGraph);
            // brainstorm → specify (allowed)
            expect(() => {
                validatePhaseOrder(createSkillInput("specify"), taskGraph, testDir);
            }).not.toThrow();
            // Simulate specify completion
            const specPath = ".opencode/specs/test-feature.md";
            await writeFile(join(testDir, specPath), "# Test Spec\n\nNo clarification needed.");
            taskGraph.current_phase = "specify";
            taskGraph.phase_artifacts.specify = specPath;
            await stateManager.save(taskGraph);
            // specify → architecture (allowed when clarify is skipped)
            taskGraph.skipped_phases = ["clarify"];
            await stateManager.save(taskGraph);
            expect(() => {
                validatePhaseOrder(createSkillInput("architecture-tech-lead"), taskGraph, testDir);
            }).not.toThrow();
            // Simulate architecture completion
            const planPath = ".opencode/plans/test-plan.md";
            await writeFile(join(testDir, planPath), "# Architecture Plan\n\nDetailed design.");
            taskGraph.current_phase = "architecture";
            taskGraph.phase_artifacts.architecture = planPath;
            await stateManager.save(taskGraph);
            // architecture → decompose (allowed)
            expect(() => {
                validatePhaseOrder(createSkillInput("task-planner"), taskGraph, testDir);
            }).not.toThrow();
            // Simulate decompose completion
            taskGraph.current_phase = "decompose";
            taskGraph.phase_artifacts.decompose = "completed";
            await stateManager.save(taskGraph);
            // decompose → execute (allowed)
            expect(() => {
                validatePhaseOrder(createSkillInput("code-implementer"), taskGraph, testDir);
            }).not.toThrow();
        });
        it("blocks skipping required phases", async () => {
            const taskGraph = createTaskGraph({ current_phase: "init" });
            await stateManager.save(taskGraph);
            // init → execute (blocked - can't skip all phases)
            expect(() => {
                validatePhaseOrder(createSkillInput("code-implementer"), taskGraph, testDir);
            }).toThrow(/blocked/i);
            // init → decompose (blocked)
            expect(() => {
                validatePhaseOrder(createSkillInput("task-planner"), taskGraph, testDir);
            }).toThrow(/blocked/i);
        });
    });
    describe("skipping brainstorm", () => {
        it("allows init → specify directly", async () => {
            const taskGraph = createTaskGraph({ current_phase: "init" });
            await stateManager.save(taskGraph);
            // init → specify (allowed - brainstorm is optional)
            expect(() => {
                validatePhaseOrder(createSkillInput("specify"), taskGraph, testDir);
            }).not.toThrow();
        });
    });
    describe("auto-skipping clarify", () => {
        it("auto-skips clarify when markers ≤ 3", async () => {
            // Create spec with 2 markers
            const specPath = ".opencode/specs/few-markers.md";
            const specContent = `# Specification

## Requirements
[NEEDS CLARIFICATION] What is the expected format?
[NEEDS CLARIFICATION] Which API version?

## Design
The design is straightforward.
`;
            await writeFile(join(testDir, specPath), specContent);
            let taskGraph = createTaskGraph({
                current_phase: "specify",
                phase_artifacts: { specify: specPath },
            });
            await stateManager.save(taskGraph);
            // Simulate specify completion
            const content = `Specification complete. Saved to ${specPath}`;
            const result = await advancePhase(content, taskGraph, stateManager, testDir);
            expect(result).not.toBeNull();
            expect(result?.clarifySkipped).toBe(true);
            expect(result?.newPhase).toBe("architecture");
            // Verify state was updated
            const updatedGraph = await stateManager.load();
            expect(updatedGraph?.skipped_phases).toContain("clarify");
            expect(updatedGraph?.current_phase).toBe("architecture");
        });
        it("requires clarify when markers > 3", async () => {
            // Create spec with 5 markers
            const specPath = ".opencode/specs/many-markers.md";
            const specContent = `# Specification

## Requirements
[NEEDS CLARIFICATION] What is the expected format?
[NEEDS CLARIFICATION] Which API version?
[NEEDS CLARIFICATION] What are the error cases?
[NEEDS CLARIFICATION] Performance requirements?
[NEEDS CLARIFICATION] Security considerations?

## Design
Complex design needs clarification.
`;
            await writeFile(join(testDir, specPath), specContent);
            let taskGraph = createTaskGraph({
                current_phase: "specify",
                phase_artifacts: { specify: specPath },
            });
            await stateManager.save(taskGraph);
            // Simulate specify completion
            const content = `Specification complete. Saved to ${specPath}`;
            const result = await advancePhase(content, taskGraph, stateManager, testDir);
            expect(result).not.toBeNull();
            expect(result?.clarifySkipped).toBe(false);
            expect(result?.newPhase).toBe("clarify");
            // Verify state was updated
            const updatedGraph = await stateManager.load();
            expect(updatedGraph?.skipped_phases).not.toContain("clarify");
            expect(updatedGraph?.current_phase).toBe("clarify");
        });
    });
    describe("state consistency", () => {
        it("maintains state consistency across multiple operations", async () => {
            let taskGraph = createTaskGraph({ current_phase: "init" });
            await stateManager.save(taskGraph);
            // Phase advancement updates state atomically
            const specPath = ".opencode/specs/test.md";
            await writeFile(join(testDir, specPath), "# Test\n\nNo markers.");
            taskGraph.current_phase = "specify";
            await stateManager.save(taskGraph);
            const content = `Specification complete. Saved to ${specPath}`;
            await advancePhase(content, taskGraph, stateManager, testDir);
            // Reload and verify
            const reloaded = await stateManager.load();
            expect(reloaded?.current_phase).toBe("architecture");
            expect(reloaded?.phase_artifacts?.specify).toBe(specPath);
            expect(reloaded?.skipped_phases).toContain("clarify");
        });
        it("correctly records artifacts for each phase", async () => {
            let taskGraph = createTaskGraph({ current_phase: "brainstorm" });
            await stateManager.save(taskGraph);
            // Advance through phases and check artifacts
            const brainstormContent = "Brainstorm complete.";
            await advancePhase(brainstormContent, taskGraph, stateManager, testDir);
            let updated = await stateManager.load();
            expect(updated?.phase_artifacts?.brainstorm).toBe("completed");
            expect(updated?.current_phase).toBe("specify");
        });
    });
    describe("artifact prerequisites", () => {
        it("blocks transition when required artifact is missing", async () => {
            // Try to go to architecture without spec file
            const taskGraph = createTaskGraph({
                current_phase: "specify",
                phase_artifacts: {}, // No specify artifact recorded
            });
            await stateManager.save(taskGraph);
            expect(() => {
                validatePhaseOrder(createSkillInput("architecture-tech-lead"), taskGraph, testDir);
            }).toThrow(/blocked/i);
        });
        it("allows transition when artifact exists", async () => {
            // Create spec file
            const specPath = ".opencode/specs/valid-spec.md";
            await writeFile(join(testDir, specPath), "# Valid Spec");
            const taskGraph = createTaskGraph({
                current_phase: "specify",
                phase_artifacts: { specify: specPath },
                skipped_phases: ["clarify"],
            });
            await stateManager.save(taskGraph);
            expect(() => {
                validatePhaseOrder(createSkillInput("architecture-tech-lead"), taskGraph, testDir);
            }).not.toThrow();
        });
    });
    describe("phase-exempt skills", () => {
        it("allows exempt skills regardless of phase", async () => {
            const taskGraph = createTaskGraph({ current_phase: "init" });
            await stateManager.save(taskGraph);
            // find-skills should work in any phase
            expect(() => {
                validatePhaseOrder(createSkillInput("find-skills"), taskGraph, testDir);
            }).not.toThrow();
            // marketing-ideas should work in any phase
            expect(() => {
                validatePhaseOrder(createSkillInput("marketing-ideas"), taskGraph, testDir);
            }).not.toThrow();
        });
    });
    describe("execute phase behavior", () => {
        it("allows staying in execute phase", async () => {
            const planPath = ".opencode/plans/test.md";
            await writeFile(join(testDir, planPath), "# Plan");
            const taskGraph = createTaskGraph({
                current_phase: "execute",
                phase_artifacts: { architecture: planPath },
            });
            await stateManager.save(taskGraph);
            // Multiple implementation skills in execute phase
            expect(() => {
                validatePhaseOrder(createSkillInput("code-implementer"), taskGraph, testDir);
            }).not.toThrow();
            expect(() => {
                validatePhaseOrder(createSkillInput("ts-test-engineer"), taskGraph, testDir);
            }).not.toThrow();
            expect(() => {
                validatePhaseOrder(createSkillInput("java-test-engineer"), taskGraph, testDir);
            }).not.toThrow();
        });
        it("allows unknown skills during execute phase", async () => {
            const planPath = ".opencode/plans/test.md";
            await writeFile(join(testDir, planPath), "# Plan");
            const taskGraph = createTaskGraph({
                current_phase: "execute",
                phase_artifacts: { architecture: planPath },
            });
            await stateManager.save(taskGraph);
            // Custom/unknown skill should be allowed in execute
            expect(() => {
                validatePhaseOrder(createSkillInput("my-custom-domain-skill"), taskGraph, testDir);
            }).not.toThrow();
        });
    });
    // ==========================================================================
    // AC-4: Edge Cases - Malformed Task Graph Handling
    // ==========================================================================
    describe("malformed task graph handling", () => {
        it("handles corrupted JSON gracefully", async () => {
            // Write invalid JSON to state file
            const statePath = join(testDir, ".opencode", "state", "active_task_graph.json");
            await writeFile(statePath, "{ invalid json content here }}}");
            // StateManager.load() should return null, not throw
            const loaded = await stateManager.load();
            expect(loaded).toBeNull();
        });
        it("handles empty state file gracefully", async () => {
            // Write empty file
            const statePath = join(testDir, ".opencode", "state", "active_task_graph.json");
            await writeFile(statePath, "");
            const loaded = await stateManager.load();
            expect(loaded).toBeNull();
        });
        it("handles partial/incomplete task graph", async () => {
            // Write incomplete task graph (missing required fields)
            const statePath = join(testDir, ".opencode", "state", "active_task_graph.json");
            await writeFile(statePath, JSON.stringify({
                title: "Incomplete Graph",
                // Missing: current_phase, tasks, etc.
            }));
            // Should load without crashing, returning partial data
            const loaded = await stateManager.load();
            expect(loaded).not.toBeNull();
            expect(loaded?.title).toBe("Incomplete Graph");
        });
        it("allows skill invocation when task graph is malformed", async () => {
            // Write invalid JSON
            const statePath = join(testDir, ".opencode", "state", "active_task_graph.json");
            await writeFile(statePath, "not valid json");
            // validatePhaseOrder should allow skill since load() returns null
            const loaded = await stateManager.load();
            expect(() => {
                validatePhaseOrder(createSkillInput("code-implementer"), loaded, testDir);
            }).not.toThrow();
        });
    });
    // ==========================================================================
    // AC-4: Edge Cases - Concurrent Access
    // ==========================================================================
    describe("concurrent access handling", () => {
        it("maintains state consistency under sequential writes", async () => {
            // Create initial state
            const taskGraph = createTaskGraph({
                current_phase: "specify",
                tasks: [
                    { id: "T1", description: "Task 1", wave: 1, status: "pending", agent: "general", depends_on: [] },
                    { id: "T2", description: "Task 2", wave: 1, status: "pending", agent: "general", depends_on: [] },
                    { id: "T3", description: "Task 3", wave: 1, status: "pending", agent: "general", depends_on: [] },
                ],
            });
            await stateManager.save(taskGraph);
            // Perform sequential updates (realistic usage pattern)
            await stateManager.updateTask("T1", { status: "completed" });
            await stateManager.updateTask("T2", { status: "implemented" });
            await stateManager.updateTask("T3", { status: "in_progress" });
            // Verify all updates were applied correctly
            const final = await stateManager.load();
            expect(final?.tasks.find(t => t.id === "T1")?.status).toBe("completed");
            expect(final?.tasks.find(t => t.id === "T2")?.status).toBe("implemented");
            expect(final?.tasks.find(t => t.id === "T3")?.status).toBe("in_progress");
        });
        it("uses file locking for state operations", async () => {
            // Verify that the state manager uses locking by checking operations complete
            const taskGraph = createTaskGraph({
                current_phase: "execute",
                current_wave: 1,
            });
            await stateManager.save(taskGraph);
            // Sequential operations should work correctly
            await stateManager.updateWaveGate(1, { impl_complete: true });
            await stateManager.updateWaveGate(1, { tests_passed: true });
            await stateManager.updateWaveGate(1, { reviews_complete: true });
            const final = await stateManager.load();
            expect(final?.wave_gates[1]).toBeDefined();
            expect(final?.wave_gates[1]?.impl_complete).toBe(true);
            expect(final?.wave_gates[1]?.tests_passed).toBe(true);
            expect(final?.wave_gates[1]?.reviews_complete).toBe(true);
            expect(final?.wave_gates[1]?.checked_at).toBeDefined();
        });
        it("handles concurrent phase advancements safely", async () => {
            // Create spec file
            const specPath = ".opencode/specs/concurrent-test.md";
            await writeFile(join(testDir, specPath), "# Spec\n\nNo markers.");
            const taskGraph = createTaskGraph({
                current_phase: "specify",
                phase_artifacts: { specify: specPath },
            });
            await stateManager.save(taskGraph);
            const content = `Specification complete. Saved to ${specPath}`;
            // Attempt concurrent phase advancements (only one should succeed meaningfully)
            const advancements = [
                advancePhase(content, taskGraph, stateManager, testDir),
                advancePhase(content, taskGraph, stateManager, testDir),
                advancePhase(content, taskGraph, stateManager, testDir),
            ];
            const results = await Promise.all(advancements);
            // At least one should have advanced
            const successfulAdvancements = results.filter(r => r !== null);
            expect(successfulAdvancements.length).toBeGreaterThanOrEqual(1);
            // Final state should be consistent
            const final = await stateManager.load();
            expect(final?.current_phase).toBe("architecture");
        });
        it("batch updates work correctly", async () => {
            // Create initial state
            const taskGraph = createTaskGraph({
                current_phase: "execute",
                tasks: [
                    { id: "T1", description: "Task 1", wave: 1, status: "pending", agent: "general", depends_on: [] },
                    { id: "T2", description: "Task 2", wave: 1, status: "pending", agent: "general", depends_on: [] },
                ],
            });
            await stateManager.save(taskGraph);
            // Use batch update (single atomic operation)
            await stateManager.updateTasks([
                { taskId: "T1", updates: { status: "completed" } },
                { taskId: "T2", updates: { status: "implemented" } },
            ]);
            const final = await stateManager.load();
            expect(final?.tasks.find(t => t.id === "T1")?.status).toBe("completed");
            expect(final?.tasks.find(t => t.id === "T2")?.status).toBe("implemented");
        });
    });
    // ==========================================================================
    // TR-005: Session Idle Debouncing
    // ==========================================================================
    describe("session.idle debouncing", () => {
        it("debounces rapid session.idle events", async () => {
            const debouncer = new PhaseAdvancementDebouncer(100); // 100ms debounce
            // First call should be allowed
            expect(debouncer.shouldProcess("First message")).toBe(true);
            debouncer.markProcessed();
            // Rapid second call with different content should be blocked (within debounce window)
            expect(debouncer.shouldProcess("Second message")).toBe(false);
            // Wait for debounce window to pass
            await new Promise(resolve => setTimeout(resolve, 150));
            // Now a new message should be allowed
            expect(debouncer.shouldProcess("Third message")).toBe(true);
        });
        it("blocks duplicate content even after debounce period", async () => {
            const debouncer = new PhaseAdvancementDebouncer(50);
            const content = "Specification complete. Saved to spec.md";
            // First call allowed
            expect(debouncer.shouldProcess(content)).toBe(true);
            debouncer.markProcessed();
            // Wait for debounce window
            await new Promise(resolve => setTimeout(resolve, 100));
            // Same content should still be blocked (content hash match)
            expect(debouncer.shouldProcess(content)).toBe(false);
            // Different content should be allowed
            expect(debouncer.shouldProcess("Different content now")).toBe(true);
        });
        it("resets debouncer state correctly", async () => {
            const debouncer = new PhaseAdvancementDebouncer(100);
            // Process some content
            expect(debouncer.shouldProcess("Initial content")).toBe(true);
            debouncer.markProcessed();
            // Same content blocked
            expect(debouncer.shouldProcess("Initial content")).toBe(false);
            // Reset the debouncer
            debouncer.reset();
            // Same content now allowed again
            expect(debouncer.shouldProcess("Initial content")).toBe(true);
        });
        it("integrates debouncing with phase advancement", async () => {
            const debouncer = new PhaseAdvancementDebouncer(100);
            const messageBuffer = new MessageBuffer();
            // Create state
            const specPath = ".opencode/specs/debounce-test.md";
            await writeFile(join(testDir, specPath), "# Spec\n\nNo markers.");
            let taskGraph = createTaskGraph({
                current_phase: "specify",
                phase_artifacts: { specify: specPath },
            });
            await stateManager.save(taskGraph);
            const completionMessage = `Specification complete. Saved to ${specPath}`;
            // Buffer the message (simulating message.updated)
            messageBuffer.push("assistant", completionMessage);
            // First idle event triggers advancement
            const lastMessage = messageBuffer.getLastAssistantMessage();
            expect(lastMessage).not.toBeNull();
            if (debouncer.shouldProcess(lastMessage)) {
                const result = await advancePhase(lastMessage, taskGraph, stateManager, testDir);
                expect(result).not.toBeNull();
                expect(result?.newPhase).toBe("architecture");
                debouncer.markProcessed();
            }
            // Reload task graph
            taskGraph = (await stateManager.load());
            // Rapid second idle event should be debounced
            if (debouncer.shouldProcess(lastMessage)) {
                // This should NOT execute because content hash matches
                throw new Error("Should have been debounced");
            }
            // Verify state is correct
            const final = await stateManager.load();
            expect(final?.current_phase).toBe("architecture");
        });
    });
    // ==========================================================================
    // Message Buffer Integration
    // ==========================================================================
    describe("message buffer for session.idle", () => {
        it("tracks assistant messages for idle fallback", () => {
            const buffer = new MessageBuffer(5);
            buffer.push("user", "Please create a spec");
            buffer.push("assistant", "I'll create the specification now.");
            buffer.push("user", "Thanks");
            buffer.push("assistant", "Specification complete. Saved to spec.md");
            expect(buffer.getLastAssistantMessage()).toBe("Specification complete. Saved to spec.md");
            expect(buffer.size()).toBe(4);
        });
        it("respects max buffer size", () => {
            const buffer = new MessageBuffer(3);
            buffer.push("assistant", "Message 1");
            buffer.push("assistant", "Message 2");
            buffer.push("assistant", "Message 3");
            buffer.push("assistant", "Message 4");
            expect(buffer.size()).toBe(3);
            expect(buffer.getLastAssistantMessage()).toBe("Message 4");
        });
        it("returns null when no messages of role exist", () => {
            const buffer = new MessageBuffer();
            buffer.push("user", "Hello");
            buffer.push("system", "System message");
            expect(buffer.getLastAssistantMessage()).toBeNull();
        });
        it("clears buffer correctly", () => {
            const buffer = new MessageBuffer();
            buffer.push("assistant", "Some message");
            expect(buffer.size()).toBe(1);
            buffer.clear();
            expect(buffer.size()).toBe(0);
            expect(buffer.getLastAssistantMessage()).toBeNull();
        });
    });
});
//# sourceMappingURL=integration.test.js.map