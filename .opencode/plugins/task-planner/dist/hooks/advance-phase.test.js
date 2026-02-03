/**
 * Unit tests for advance-phase.ts
 *
 * Tests phase advancement logic including:
 * - Completion detection via patterns
 * - Artifact path extraction
 * - Clarification marker counting
 * - Auto-skip logic
 */
import { describe, it, expect } from "vitest";
import { detectCompletedPhase, getNextPhase, extractArtifactPath, countClarificationMarkers, detectAnyPhaseCompletion, detectTaskCompletion, } from "./advance-phase.js";
// ============================================================================
// detectCompletedPhase Tests
// ============================================================================
describe("detectCompletedPhase", () => {
    describe("brainstorm phase", () => {
        it("detects 'brainstorm is complete' pattern", () => {
            const content = "The brainstorm is complete. We explored several options.";
            expect(detectCompletedPhase(content, "brainstorm")).toBe("brainstorm");
        });
        it("detects 'brainstorming done' pattern", () => {
            const content = "Brainstorming done. Let's proceed to specification.";
            expect(detectCompletedPhase(content, "brainstorm")).toBe("brainstorm");
        });
        it("detects 'exploration is finished' pattern", () => {
            const content = "The exploration is finished. Ready for next phase.";
            expect(detectCompletedPhase(content, "brainstorm")).toBe("brainstorm");
        });
        it("does not detect brainstorm when in different phase", () => {
            const content = "The brainstorm is complete.";
            expect(detectCompletedPhase(content, "specify")).toBe(null);
        });
    });
    describe("specify phase", () => {
        it("detects 'spec complete' pattern", () => {
            const content = "Spec complete. Saved to .opencode/specs/feature.md";
            expect(detectCompletedPhase(content, "specify")).toBe("specify");
        });
        it("detects 'specification is written' pattern", () => {
            const content = "The specification is written.";
            expect(detectCompletedPhase(content, "specify")).toBe("specify");
        });
        it("detects 'created the spec' pattern", () => {
            const content = "I've created the spec at .opencode/specs/test.md";
            expect(detectCompletedPhase(content, "specify")).toBe("specify");
        });
        it("detects 'specification saved' pattern", () => {
            const content = "Specification saved to file.";
            expect(detectCompletedPhase(content, "specify")).toBe("specify");
        });
    });
    describe("clarify phase", () => {
        it("detects 'clarify complete' pattern", () => {
            const content = "Clarify complete. All questions resolved.";
            expect(detectCompletedPhase(content, "clarify")).toBe("clarify");
        });
        it("detects 'clarification resolved' pattern", () => {
            const content = "Clarification resolved. Moving to architecture.";
            expect(detectCompletedPhase(content, "clarify")).toBe("clarify");
        });
        it("detects 'clarification is done' pattern", () => {
            const content = "The clarification is done.";
            expect(detectCompletedPhase(content, "clarify")).toBe("clarify");
        });
    });
    describe("architecture phase", () => {
        it("detects 'architecture complete' pattern", () => {
            const content = "Architecture complete. Plan saved.";
            expect(detectCompletedPhase(content, "architecture")).toBe("architecture");
        });
        it("detects 'design is done' pattern", () => {
            const content = "The design is done. Ready for decomposition.";
            expect(detectCompletedPhase(content, "architecture")).toBe("architecture");
        });
        it("detects 'plan has been created' pattern", () => {
            const content = "The plan has been created at .opencode/plans/feature.md";
            expect(detectCompletedPhase(content, "architecture")).toBe("architecture");
        });
    });
    describe("decompose phase", () => {
        it("detects 'decomposition complete' pattern", () => {
            const content = "Decomposition complete. 10 tasks created.";
            expect(detectCompletedPhase(content, "decompose")).toBe("decompose");
        });
        it("detects 'tasks created' pattern", () => {
            const content = "Tasks created across 5 waves.";
            expect(detectCompletedPhase(content, "decompose")).toBe("decompose");
        });
        it("detects 'tasks have been defined' pattern", () => {
            const content = "All tasks have been defined.";
            expect(detectCompletedPhase(content, "decompose")).toBe("decompose");
        });
    });
    describe("init phase", () => {
        it("never completes via pattern", () => {
            const content = "init complete"; // Shouldn't match
            expect(detectCompletedPhase(content, "init")).toBe(null);
        });
    });
    describe("execute phase", () => {
        it("never completes via pattern (handled differently)", () => {
            const content = "T1 implemented successfully";
            expect(detectCompletedPhase(content, "execute")).toBe(null);
        });
    });
    it("returns null for non-completion messages", () => {
        expect(detectCompletedPhase("Let me think about this...", "brainstorm")).toBe(null);
        expect(detectCompletedPhase("Working on the spec now.", "specify")).toBe(null);
        expect(detectCompletedPhase("I have a question.", "clarify")).toBe(null);
    });
});
// ============================================================================
// getNextPhase Tests
// ============================================================================
describe("getNextPhase", () => {
    it("returns brainstorm after init", () => {
        expect(getNextPhase("init")).toBe("brainstorm");
    });
    it("returns specify after brainstorm", () => {
        expect(getNextPhase("brainstorm")).toBe("specify");
    });
    it("returns clarify after specify", () => {
        expect(getNextPhase("specify")).toBe("clarify");
    });
    it("returns architecture after clarify", () => {
        expect(getNextPhase("clarify")).toBe("architecture");
    });
    it("returns decompose after architecture", () => {
        expect(getNextPhase("architecture")).toBe("decompose");
    });
    it("returns execute after decompose", () => {
        expect(getNextPhase("decompose")).toBe("execute");
    });
    it("stays in execute when already in execute", () => {
        expect(getNextPhase("execute")).toBe("execute");
    });
});
// ============================================================================
// extractArtifactPath Tests
// ============================================================================
describe("extractArtifactPath", () => {
    it("extracts path from 'saved to X' pattern", () => {
        const content = "Specification saved to .opencode/specs/feature.md";
        expect(extractArtifactPath(content)).toBe(".opencode/specs/feature.md");
    });
    it("extracts path from 'created X' pattern", () => {
        const content = "I've created .opencode/plans/test.md for you.";
        expect(extractArtifactPath(content)).toBe(".opencode/plans/test.md");
    });
    it("extracts path from 'wrote to X' pattern", () => {
        const content = "Wrote to .opencode/specs/api.md";
        expect(extractArtifactPath(content)).toBe(".opencode/specs/api.md");
    });
    it("extracts path from 'generated X' pattern", () => {
        const content = "Generated .opencode/plans/architecture.md";
        expect(extractArtifactPath(content)).toBe(".opencode/plans/architecture.md");
    });
    it("handles quoted paths", () => {
        const content = "Saved to '.opencode/specs/test.md'";
        expect(extractArtifactPath(content)).toBe(".opencode/specs/test.md");
    });
    it("returns 'completed' when no path found", () => {
        const content = "The brainstorm is complete.";
        expect(extractArtifactPath(content)).toBe("completed");
    });
    it("returns 'completed' for empty content", () => {
        expect(extractArtifactPath("")).toBe("completed");
    });
});
// ============================================================================
// countClarificationMarkers Tests
// ============================================================================
describe("countClarificationMarkers", () => {
    // Note: These tests would need file system mocking in a real scenario
    // For now, we test with non-existent paths which should return 0
    it("returns 0 for non-existent file", async () => {
        const result = await countClarificationMarkers("/non/existent/path.md");
        expect(result).toBe(0);
    });
    it("returns 0 for empty path", async () => {
        const result = await countClarificationMarkers("");
        expect(result).toBe(0);
    });
});
// ============================================================================
// detectAnyPhaseCompletion Tests
// ============================================================================
describe("detectAnyPhaseCompletion", () => {
    it("detects brainstorm completion", () => {
        const content = "The brainstorm is complete.";
        expect(detectAnyPhaseCompletion(content)).toBe("brainstorm");
    });
    it("detects specify completion", () => {
        const content = "Spec complete. Saved to file.";
        expect(detectAnyPhaseCompletion(content)).toBe("specify");
    });
    it("detects architecture completion", () => {
        const content = "The architecture is complete.";
        expect(detectAnyPhaseCompletion(content)).toBe("architecture");
    });
    it("returns null for non-completion content", () => {
        const content = "Working on the implementation...";
        expect(detectAnyPhaseCompletion(content)).toBe(null);
    });
});
// ============================================================================
// detectTaskCompletion Tests
// ============================================================================
describe("detectTaskCompletion", () => {
    it("detects 'T1 implemented' pattern", () => {
        const content = "T1 implemented successfully.";
        expect(detectTaskCompletion(content)).toBe("T1");
    });
    it("detects 'Task 3 complete' pattern", () => {
        const content = "Task 3 is now complete.";
        expect(detectTaskCompletion(content)).toBe("T3");
    });
    it("detects 'T5 done' pattern", () => {
        const content = "T5 done. Moving to next task.";
        expect(detectTaskCompletion(content)).toBe("T5");
    });
    it("detects 'Task 10 finished' pattern", () => {
        const content = "Task 10 finished!";
        expect(detectTaskCompletion(content)).toBe("T10");
    });
    it("returns null for non-task-completion content", () => {
        const content = "Working on T1...";
        expect(detectTaskCompletion(content)).toBe(null);
    });
    it("returns null when no task mentioned", () => {
        const content = "Implementation complete.";
        expect(detectTaskCompletion(content)).toBe(null);
    });
});
//# sourceMappingURL=advance-phase.test.js.map