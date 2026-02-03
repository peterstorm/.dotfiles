/**
 * Unit tests for validate-phase-order.ts
 *
 * Tests phase validation logic including:
 * - Skill-to-phase mapping
 * - Valid/invalid transitions
 * - Artifact prerequisites
 * - Phase-exempt skills
 * - Unknown skill handling
 */
import { describe, it, expect, vi } from "vitest";
import { validatePhaseOrder, isValidTransition, checkArtifactPrerequisites, isPhaseExempt, getPhaseForSkill, isValidArtifactPath, } from "./validate-phase-order.js";
// ============================================================================
// Test Fixtures
// ============================================================================
function createTaskGraph(overrides = {}) {
    return {
        title: "Test Task Graph",
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
function createNonSkillInput(tool) {
    return {
        tool,
        args: { path: "/some/path" },
    };
}
// ============================================================================
// validatePhaseOrder Tests
// ============================================================================
describe("validatePhaseOrder", () => {
    const projectDir = "/test/project";
    describe("when no task graph exists", () => {
        it("allows any skill invocation", () => {
            const input = createSkillInput("code-implementer");
            expect(() => {
                validatePhaseOrder(input, null, projectDir);
            }).not.toThrow();
        });
    });
    describe("when task graph exists", () => {
        describe("non-skill tools", () => {
            it("allows Read tool without validation", () => {
                const taskGraph = createTaskGraph({ current_phase: "init" });
                const input = createNonSkillInput("Read");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).not.toThrow();
            });
            it("allows Bash tool without validation", () => {
                const taskGraph = createTaskGraph({ current_phase: "init" });
                const input = createNonSkillInput("Bash");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).not.toThrow();
            });
        });
        describe("skill-to-phase mapping", () => {
            it("maps brainstorming to brainstorm phase", () => {
                expect(getPhaseForSkill("brainstorming")).toBe("brainstorm");
            });
            it("maps specify to specify phase", () => {
                expect(getPhaseForSkill("specify")).toBe("specify");
            });
            it("maps clarify to clarify phase", () => {
                expect(getPhaseForSkill("clarify")).toBe("clarify");
            });
            it("maps architecture-tech-lead to architecture phase", () => {
                expect(getPhaseForSkill("architecture-tech-lead")).toBe("architecture");
            });
            it("maps task-planner to decompose phase", () => {
                expect(getPhaseForSkill("task-planner")).toBe("decompose");
            });
            it("maps code-implementer to execute phase", () => {
                expect(getPhaseForSkill("code-implementer")).toBe("execute");
            });
            it("maps java-test-engineer to execute phase", () => {
                expect(getPhaseForSkill("java-test-engineer")).toBe("execute");
            });
            it("maps ts-test-engineer to execute phase", () => {
                expect(getPhaseForSkill("ts-test-engineer")).toBe("execute");
            });
            it("returns undefined for unknown skill", () => {
                expect(getPhaseForSkill("unknown-skill")).toBeUndefined();
            });
            it("is case-insensitive", () => {
                expect(getPhaseForSkill("BRAINSTORMING")).toBe("brainstorm");
                expect(getPhaseForSkill("code-implementer")).toBe("execute");
                expect(getPhaseForSkill("SPECIFY")).toBe("specify");
            });
        });
        describe("valid transitions", () => {
            it("allows init → brainstorm", () => {
                const taskGraph = createTaskGraph({ current_phase: "init" });
                const input = createSkillInput("brainstorming");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).not.toThrow();
            });
            it("allows init → specify (skipping brainstorm)", () => {
                const taskGraph = createTaskGraph({ current_phase: "init" });
                const input = createSkillInput("specify");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).not.toThrow();
            });
            it("allows brainstorm → specify", () => {
                const taskGraph = createTaskGraph({
                    current_phase: "brainstorm",
                    phase_artifacts: { brainstorm: "completed" },
                });
                const input = createSkillInput("specify");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).not.toThrow();
            });
            it("allows specify → clarify", () => {
                // Note: This may fail artifact check, but transition is valid
                expect(isValidTransition("specify", "clarify", [])).toBe(true);
            });
            it("allows specify → architecture (when clarify skipped)", () => {
                expect(isValidTransition("specify", "architecture", ["clarify"])).toBe(true);
            });
            it("allows clarify → architecture", () => {
                expect(isValidTransition("clarify", "architecture", [])).toBe(true);
            });
            it("allows architecture → decompose", () => {
                expect(isValidTransition("architecture", "decompose", [])).toBe(true);
            });
            it("allows decompose → execute", () => {
                expect(isValidTransition("decompose", "execute", [])).toBe(true);
            });
            it("allows execute → execute (multiple tasks)", () => {
                expect(isValidTransition("execute", "execute", [])).toBe(true);
            });
        });
        describe("invalid transitions", () => {
            it("blocks init → execute", () => {
                const taskGraph = createTaskGraph({ current_phase: "init" });
                const input = createSkillInput("code-implementer");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).toThrow(/blocked/i);
            });
            it("blocks init → architecture", () => {
                const taskGraph = createTaskGraph({ current_phase: "init" });
                const input = createSkillInput("architecture-tech-lead");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).toThrow(/blocked/i);
            });
            it("blocks brainstorm → architecture", () => {
                expect(isValidTransition("brainstorm", "architecture", [])).toBe(false);
            });
            it("blocks brainstorm → execute", () => {
                expect(isValidTransition("brainstorm", "execute", [])).toBe(false);
            });
            it("blocks specify → execute", () => {
                expect(isValidTransition("specify", "execute", [])).toBe(false);
            });
            it("blocks specify → decompose (not a direct transition)", () => {
                // specify can only go to clarify or architecture, not decompose
                expect(isValidTransition("specify", "decompose", [])).toBe(false);
            });
        });
        describe("phase-exempt skills", () => {
            it("allows find-skills regardless of phase", () => {
                expect(isPhaseExempt("find-skills")).toBe(true);
            });
            it("allows marketing-ideas regardless of phase", () => {
                expect(isPhaseExempt("marketing-ideas")).toBe(true);
            });
            it("allows writing-clearly-and-concisely", () => {
                expect(isPhaseExempt("writing-clearly-and-concisely")).toBe(true);
            });
            it("does not exempt phase skills", () => {
                expect(isPhaseExempt("code-implementer")).toBe(false);
                expect(isPhaseExempt("specify")).toBe(false);
            });
        });
        describe("unknown skills", () => {
            it("blocks unknown skill during non-execute phase", () => {
                const taskGraph = createTaskGraph({ current_phase: "specify" });
                const input = createSkillInput("my-custom-skill");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).toThrow(/unrecognized skill/i);
            });
            it("allows unknown skill during execute phase", () => {
                const taskGraph = createTaskGraph({ current_phase: "execute" });
                const input = createSkillInput("my-custom-skill");
                expect(() => {
                    validatePhaseOrder(input, taskGraph, projectDir);
                }).not.toThrow();
            });
        });
    });
});
// ============================================================================
// isValidTransition Tests
// ============================================================================
describe("isValidTransition", () => {
    it("always allows same-phase transitions", () => {
        const phases = [
            "init",
            "brainstorm",
            "specify",
            "clarify",
            "architecture",
            "decompose",
            "execute",
        ];
        for (const phase of phases) {
            expect(isValidTransition(phase, phase, [])).toBe(true);
        }
    });
    it("prevents backward transitions", () => {
        expect(isValidTransition("specify", "brainstorm", [])).toBe(false);
        expect(isValidTransition("execute", "specify", [])).toBe(false);
        expect(isValidTransition("decompose", "architecture", [])).toBe(false);
    });
});
// ============================================================================
// checkArtifactPrerequisites Tests
// ============================================================================
describe("checkArtifactPrerequisites", () => {
    const projectDir = "/test/project";
    it("returns valid for init phase (no prerequisites)", () => {
        const taskGraph = createTaskGraph({ current_phase: "init" });
        const result = checkArtifactPrerequisites("brainstorm", taskGraph, projectDir);
        expect(result.valid).toBe(true);
    });
    it("returns valid when artifact is 'completed'", () => {
        const taskGraph = createTaskGraph({
            current_phase: "brainstorm",
            phase_artifacts: { brainstorm: "completed" },
        });
        const result = checkArtifactPrerequisites("specify", taskGraph, projectDir);
        expect(result.valid).toBe(true);
    });
    it("returns invalid when prerequisite artifact is missing", () => {
        const taskGraph = createTaskGraph({
            current_phase: "specify",
            phase_artifacts: {},
        });
        const result = checkArtifactPrerequisites("clarify", taskGraph, projectDir);
        expect(result.valid).toBe(false);
        expect(result.missing).toContain("specify");
    });
});
// ============================================================================
// isValidArtifactPath Tests
// ============================================================================
describe("isValidArtifactPath", () => {
    it("allows .opencode/specs/ paths", () => {
        expect(isValidArtifactPath(".opencode/specs/test.md")).toBe(true);
        expect(isValidArtifactPath(".opencode/specs/feature/spec.md")).toBe(true);
    });
    it("allows .opencode/plans/ paths", () => {
        expect(isValidArtifactPath(".opencode/plans/test.md")).toBe(true);
        expect(isValidArtifactPath(".opencode/plans/2024/plan.md")).toBe(true);
    });
    it("allows legacy .claude/ paths with warning", () => {
        // Suppress console.warn for this test
        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => { });
        expect(isValidArtifactPath(".claude/specs/test.md")).toBe(true);
        expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("Legacy"));
        warnSpy.mockRestore();
    });
    it("rejects paths outside allowed directories", () => {
        expect(isValidArtifactPath("src/test.md")).toBe(false);
        expect(isValidArtifactPath("../evil.md")).toBe(false);
        expect(isValidArtifactPath("/etc/passwd")).toBe(false);
    });
});
//# sourceMappingURL=validate-phase-order.test.js.map