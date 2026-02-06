/**
 * Unit tests for guard-state-file.ts
 *
 * Tests the hook that prevents Bash commands from writing to state files.
 */
import { describe, it, expect } from "vitest";
import { guardStateFile, isProtectedPath, getProtectedPatterns, extractPathsFromCommand, } from "./guard-state-file.js";
// ============================================================================
// Test Fixtures
// ============================================================================
function createTaskGraph(overrides = {}) {
    return {
        title: "Test Task Graph",
        spec_file: ".opencode/specs/test/spec.md",
        plan_file: ".opencode/plans/test.md",
        current_phase: "execute",
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
function createBashInput(command) {
    return {
        tool: "Bash",
        args: { command },
    };
}
// ============================================================================
// guardStateFile Tests
// ============================================================================
describe("guardStateFile", () => {
    describe("non-Bash tools", () => {
        it("allows Edit tool without validation", () => {
            const taskGraph = createTaskGraph();
            const input = {
                tool: "Edit",
                args: { filePath: ".opencode/state/test.json" },
            };
            expect(() => {
                guardStateFile(input, taskGraph);
            }).not.toThrow();
        });
        it("allows Read tool without validation", () => {
            const taskGraph = createTaskGraph();
            const input = {
                tool: "Read",
                args: { filePath: ".opencode/state/test.json" },
            };
            expect(() => {
                guardStateFile(input, taskGraph);
            }).not.toThrow();
        });
    });
    describe("Bash tool with safe commands", () => {
        it("allows read-only commands", () => {
            const taskGraph = createTaskGraph();
            const safeCommands = [
                "cat .opencode/state/test.json",
                "ls .opencode/state/",
                "head .opencode/specs/test.md",
                "grep pattern .opencode/plans/test.md",
            ];
            for (const command of safeCommands) {
                const input = createBashInput(command);
                expect(() => {
                    guardStateFile(input, taskGraph);
                }).not.toThrow();
            }
        });
        it("allows write commands to non-protected paths", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("echo hello > /tmp/test.txt");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).not.toThrow();
        });
        it("allows write commands without targeting files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("npm run build");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).not.toThrow();
        });
    });
    describe("Bash tool with protected file writes", () => {
        it("blocks echo to state JSON files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput('echo "{}" > .opencode/state/test.json');
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks printf to state JSON files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput('printf "{}" > .opencode/state/test.json');
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks cat to state files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("cat foo.json > .opencode/state/test.json");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks tee to spec files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("echo 'content' | tee .opencode/specs/test.md");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks cp to plan files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("cp source.md .opencode/plans/test.md");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks mv to state files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("mv temp.json .opencode/state/test.json");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks rm on state files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("rm .opencode/state/test.json");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks sed -i on spec files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("sed -i 's/old/new/g' .opencode/specs/test.md");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks awk output redirection to state files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("awk '{print}' foo > .opencode/state/test.json");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
    });
    describe("legacy .claude/ paths", () => {
        it("blocks writes to .claude/state/ files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput('echo "{}" > .claude/state/test.json');
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks writes to .claude/specs/ files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("cp foo.md .claude/specs/test.md");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
        it("blocks writes to .claude/plans/ files", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput("mv bar.md .claude/plans/test.md");
            expect(() => {
                guardStateFile(input, taskGraph);
            }).toThrow(/blocked/i);
        });
    });
    describe("error message", () => {
        it("includes the blocked file path", () => {
            const taskGraph = createTaskGraph();
            const input = createBashInput('echo "{}" > .opencode/state/active_task_graph.json');
            try {
                guardStateFile(input, taskGraph);
                expect.fail("Should have thrown");
            }
            catch (error) {
                const message = error.message;
                expect(message).toContain(".opencode/state");
            }
        });
    });
});
// ============================================================================
// isProtectedPath Tests
// ============================================================================
describe("isProtectedPath", () => {
    describe("protected paths", () => {
        it("protects .opencode/state/*.json", () => {
            expect(isProtectedPath(".opencode/state/test.json")).toBe(true);
            expect(isProtectedPath(".opencode/state/active_task_graph.json")).toBe(true);
        });
        it("protects .opencode/specs/*.md", () => {
            expect(isProtectedPath(".opencode/specs/test.md")).toBe(true);
            expect(isProtectedPath(".opencode/specs/feature/spec.md")).toBe(true);
        });
        it("protects .opencode/plans/*.md", () => {
            expect(isProtectedPath(".opencode/plans/test.md")).toBe(true);
            expect(isProtectedPath(".opencode/plans/2024/plan.md")).toBe(true);
        });
        it("protects legacy .claude/ paths", () => {
            expect(isProtectedPath(".claude/state/test.json")).toBe(true);
            expect(isProtectedPath(".claude/specs/test.md")).toBe(true);
            expect(isProtectedPath(".claude/plans/test.md")).toBe(true);
        });
    });
    describe("non-protected paths", () => {
        it("does not protect src/ paths", () => {
            expect(isProtectedPath("src/test.ts")).toBe(false);
            expect(isProtectedPath("src/components/Button.tsx")).toBe(false);
        });
        it("does not protect .opencode/ non-state paths", () => {
            expect(isProtectedPath(".opencode/plugins/test.ts")).toBe(false);
            expect(isProtectedPath(".opencode/config.json")).toBe(false);
        });
        it("does not protect /tmp/ paths", () => {
            expect(isProtectedPath("/tmp/test.json")).toBe(false);
        });
    });
});
// ============================================================================
// getProtectedPatterns Tests
// ============================================================================
describe("getProtectedPatterns", () => {
    it("returns an array of RegExp patterns", () => {
        const patterns = getProtectedPatterns();
        expect(Array.isArray(patterns)).toBe(true);
        expect(patterns.length).toBeGreaterThan(0);
        expect(patterns[0]).toBeInstanceOf(RegExp);
    });
});
// ============================================================================
// extractPathsFromCommand Tests
// ============================================================================
describe("extractPathsFromCommand", () => {
    it("extracts quoted paths", () => {
        const paths = extractPathsFromCommand('cat "/path/to/file.txt"');
        expect(paths).toContain("/path/to/file.txt");
    });
    it("extracts single-quoted paths", () => {
        const paths = extractPathsFromCommand("cat '/path/to/file.txt'");
        expect(paths).toContain("/path/to/file.txt");
    });
    it("extracts paths starting with ./", () => {
        const paths = extractPathsFromCommand("cat ./src/test.json");
        expect(paths.some((p) => p.includes("./src"))).toBe(true);
    });
    it("extracts absolute paths", () => {
        const paths = extractPathsFromCommand("cat /home/user/test.json");
        expect(paths.some((p) => p.startsWith("/home"))).toBe(true);
    });
    it("extracts quoted paths with special chars", () => {
        const paths = extractPathsFromCommand('cat "./path with spaces/file.json"');
        expect(paths.some((p) => p.includes("path with spaces"))).toBe(true);
    });
});
//# sourceMappingURL=guard-state-file.test.js.map