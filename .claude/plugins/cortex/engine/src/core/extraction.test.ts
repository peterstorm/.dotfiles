/**
 * Tests for extraction parser functions.
 * Includes property-based tests with fast-check.
 */

import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import {
  truncateTranscript,
  buildExtractionPrompt,
  parseExtractionResponse,
  buildEmbeddingText,
  type MemoryCandidate,
  type GitContext,
  type MemoryType,
} from "./extraction";

describe("truncateTranscript", () => {
  it("returns full content when under maxBytes", () => {
    const content = "line1\nline2\nline3\n";
    const result = truncateTranscript(content, 1000);

    expect(result.truncated).toBe(content);
    expect(result.newCursor).toBe(content.length);
  });

  it("truncates to last complete JSONL line", () => {
    const content = "line1\nline2\nline3\n";
    const result = truncateTranscript(content, 12); // Fits "line1\nline2\n"

    expect(result.truncated).toBe("line1\nline2\n");
    expect(result.newCursor).toBe(12);
  });

  it("resumes from cursor position", () => {
    const content = "line1\nline2\nline3\n";
    const result = truncateTranscript(content, 1000, 6);

    expect(result.truncated).toBe("line2\nline3\n");
    expect(result.newCursor).toBe(content.length);
  });

  it("handles cursor at end of content", () => {
    const content = "line1\nline2\n";
    const result = truncateTranscript(content, 1000, content.length);

    expect(result.truncated).toBe("");
    expect(result.newCursor).toBe(content.length);
  });

  it("returns empty when no newline within maxBytes", () => {
    const content = "very_long_line_without_newline";
    const result = truncateTranscript(content, 10);

    expect(result.truncated).toBe("");
    expect(result.newCursor).toBe(0);
  });

  it("handles multi-byte UTF-8 characters correctly", () => {
    const content = "emoji🎉\nline2\n";
    // "emoji🎉\n" is 11 bytes (emoji=5 + 🎉=4 + \n=1 + line2=5 + \n=1 = 16 bytes)
    const result = truncateTranscript(content, 20);

    expect(result.truncated).toBe("emoji🎉\nline2\n");
    expect(result.newCursor).toBe(content.length);
  });

  it("preserves JSONL boundary with cursor and maxBytes", () => {
    const content = "line1\nline2\nline3\nline4\n";
    const result = truncateTranscript(content, 12, 6); // From "line2", max 12 bytes

    expect(result.truncated).toBe("line2\nline3\n");
    expect(result.newCursor).toBe(18); // 6 + 12
  });

  // Property-based tests
  describe("properties", () => {
    it("newCursor is always >= input cursor", () => {
      fc.assert(
        fc.property(
          fc.string({ minLength: 0, maxLength: 1000 }),
          fc.integer({ min: 1, max: 1000 }),
          fc.integer({ min: 0, max: 500 }),
          (content, maxBytes, cursor) => {
            const safeCursor = Math.min(cursor, content.length);
            const result = truncateTranscript(content, maxBytes, safeCursor);
            expect(result.newCursor).toBeGreaterThanOrEqual(safeCursor);
          }
        )
      );
    });

    it("truncated content + cursor fits within maxBytes when content has newlines", () => {
      fc.assert(
        fc.property(
          fc
            .array(fc.string({ minLength: 1, maxLength: 50 }), {
              minLength: 1,
              maxLength: 20,
            })
            .map((lines) => lines.join("\n") + "\n"),
          fc.integer({ min: 10, max: 500 }),
          (content, maxBytes) => {
            const result = truncateTranscript(content, maxBytes);
            const truncatedBytes = Buffer.byteLength(
              result.truncated,
              "utf8"
            );

            if (result.truncated.length > 0) {
              expect(truncatedBytes).toBeLessThanOrEqual(maxBytes);
            }
          }
        )
      );
    });

    it("truncated content ends with newline or is empty", () => {
      fc.assert(
        fc.property(
          fc
            .array(fc.string(), { minLength: 1, maxLength: 20 })
            .map((lines) => lines.join("\n") + "\n"),
          fc.integer({ min: 10, max: 500 }),
          fc.integer({ min: 0, max: 100 }),
          (content, maxBytes, cursor) => {
            const safeCursor = Math.min(cursor, content.length);
            const result = truncateTranscript(content, maxBytes, safeCursor);

            if (result.truncated.length > 0) {
              expect(result.truncated.endsWith("\n")).toBe(true);
            }
          }
        )
      );
    });

    it("sequential truncations with cursor resume correctly", () => {
      fc.assert(
        fc.property(
          fc
            .array(fc.string({ minLength: 1, maxLength: 30 }), {
              minLength: 5,
              maxLength: 10,
            })
            .map((lines) => lines.join("\n") + "\n"),
          fc.integer({ min: 20, max: 100 }),
          (content, maxBytes) => {
            const chunks: string[] = [];
            let cursor = 0;

            // Extract up to 10 chunks
            for (let i = 0; i < 10 && cursor < content.length; i++) {
              const result = truncateTranscript(content, maxBytes, cursor);
              if (result.truncated.length === 0) break;
              chunks.push(result.truncated);
              cursor = result.newCursor;
            }

            // Reassembled chunks should match original (up to last processed cursor)
            const reassembled = chunks.join("");
            expect(content.startsWith(reassembled)).toBe(true);
          }
        )
      );
    });
  });
});

describe("buildExtractionPrompt", () => {
  it("includes project name and branch", () => {
    const gitContext: GitContext = {
      branch: "main",
      projectName: "test-project",
    };
    const transcript = '{"role":"user","content":"test"}\n';

    const prompt = buildExtractionPrompt(transcript, gitContext);

    expect(prompt).toContain("Project: test-project");
    expect(prompt).toContain("Branch: main");
    expect(prompt).toContain(transcript);
  });

  it("includes recent commits when provided", () => {
    const gitContext: GitContext = {
      branch: "feature/test",
      projectName: "test-project",
      recentCommits: ["abc123 Initial commit", "def456 Add feature"],
    };
    const transcript = '{"role":"user","content":"test"}\n';

    const prompt = buildExtractionPrompt(transcript, gitContext);

    expect(prompt).toContain("Recent commits:");
    expect(prompt).toContain("abc123 Initial commit");
    expect(prompt).toContain("def456 Add feature");
  });

  it("includes changed files when provided", () => {
    const gitContext: GitContext = {
      branch: "main",
      projectName: "test-project",
      changedFiles: ["src/index.ts", "README.md"],
    };
    const transcript = '{"role":"user","content":"test"}\n';

    const prompt = buildExtractionPrompt(transcript, gitContext);

    expect(prompt).toContain("Changed files:");
    expect(prompt).toContain("src/index.ts");
    expect(prompt).toContain("README.md");
  });

  it("omits optional fields when not provided", () => {
    const gitContext: GitContext = {
      branch: "main",
      projectName: "test-project",
    };
    const transcript = '{"role":"user","content":"test"}\n';

    const prompt = buildExtractionPrompt(transcript, gitContext);

    expect(prompt).not.toContain("Recent commits:");
    expect(prompt).not.toContain("Changed files:");
  });

  it("includes FR requirements in prompt", () => {
    const gitContext: GitContext = {
      branch: "main",
      projectName: "test-project",
    };
    const transcript = "";

    const prompt = buildExtractionPrompt(transcript, gitContext);

    // Check for memory types (FR-005)
    expect(prompt).toContain("architecture");
    expect(prompt).toContain("decision");
    expect(prompt).toContain("pattern");
    expect(prompt).toContain("gotcha");

    // Check for confidence (FR-006)
    expect(prompt).toContain("Confidence");
    expect(prompt).toContain("0-1");

    // Check for priority (FR-007)
    expect(prompt).toContain("Priority");
    expect(prompt).toContain("1-10");

    // Check for scope classification (FR-008)
    expect(prompt).toContain("global");
    expect(prompt).toContain("project");
  });
});

describe("parseExtractionResponse", () => {
  it("parses valid JSON array of memories", () => {
    const response = JSON.stringify([
      {
        content: "Test content",
        summary: "Test summary",
        memoryType: "decision",
        category: "project",
        confidence: 0.85,
        priority: 7,
      },
    ]);

    const result = parseExtractionResponse(response);

    expect(result).toHaveLength(1);
    expect(result[0]).toEqual({
      content: "Test content",
      summary: "Test summary",
      memoryType: "decision",
      category: "project",
      confidence: 0.85,
      priority: 7,
    });
  });

  it("parses JSON wrapped in markdown code block", () => {
    const response = `\`\`\`json
[
  {
    "content": "Test",
    "summary": "Summary",
    "memoryType": "pattern",
    "category": "global",
    "confidence": 0.9,
    "priority": 8
  }
]
\`\`\``;

    const result = parseExtractionResponse(response);

    expect(result).toHaveLength(1);
    expect(result[0].memoryType).toBe("pattern");
  });

  it("returns empty array for invalid JSON", () => {
    const response = "not valid json";
    const result = parseExtractionResponse(response);

    expect(result).toEqual([]);
  });

  it("returns empty array for non-array JSON", () => {
    const response = JSON.stringify({ notAnArray: true });
    const result = parseExtractionResponse(response);

    expect(result).toEqual([]);
  });

  it("filters out invalid memory types (FR-005)", () => {
    const response = JSON.stringify([
      {
        content: "Valid",
        summary: "Valid",
        memoryType: "decision",
        category: "project",
        confidence: 0.8,
        priority: 5,
      },
      {
        content: "Invalid",
        summary: "Invalid",
        memoryType: "invalid_type",
        category: "project",
        confidence: 0.8,
        priority: 5,
      },
    ]);

    const result = parseExtractionResponse(response);

    expect(result).toHaveLength(1);
    expect(result[0].memoryType).toBe("decision");
  });

  it("filters out invalid confidence values (FR-006)", () => {
    const response = JSON.stringify([
      {
        content: "Valid",
        summary: "Valid",
        memoryType: "decision",
        category: "project",
        confidence: 0.5,
        priority: 5,
      },
      {
        content: "Too low",
        summary: "Too low",
        memoryType: "decision",
        category: "project",
        confidence: -0.1,
        priority: 5,
      },
      {
        content: "Too high",
        summary: "Too high",
        memoryType: "decision",
        category: "project",
        confidence: 1.5,
        priority: 5,
      },
    ]);

    const result = parseExtractionResponse(response);

    expect(result).toHaveLength(1);
    expect(result[0].confidence).toBe(0.5);
  });

  it("filters out invalid priority values (FR-007)", () => {
    const response = JSON.stringify([
      {
        content: "Valid",
        summary: "Valid",
        memoryType: "decision",
        category: "project",
        confidence: 0.8,
        priority: 5,
      },
      {
        content: "Too low",
        summary: "Too low",
        memoryType: "decision",
        category: "project",
        confidence: 0.8,
        priority: 0,
      },
      {
        content: "Too high",
        summary: "Too high",
        memoryType: "decision",
        category: "project",
        confidence: 0.8,
        priority: 11,
      },
      {
        content: "Not integer",
        summary: "Not integer",
        memoryType: "decision",
        category: "project",
        confidence: 0.8,
        priority: 5.5,
      },
    ]);

    const result = parseExtractionResponse(response);

    expect(result).toHaveLength(1);
    expect(result[0].priority).toBe(5);
  });

  it("validates all 8 memory types", () => {
    const memoryTypes: MemoryType[] = [
      "architecture",
      "decision",
      "pattern",
      "gotcha",
      "context",
      "progress",
      "code_description",
      "code",
    ];

    memoryTypes.forEach((type) => {
      const response = JSON.stringify([
        {
          content: `Test ${type}`,
          summary: `Summary ${type}`,
          memoryType: type,
          category: "project",
          confidence: 0.8,
          priority: 5,
        },
      ]);

      const result = parseExtractionResponse(response);
      expect(result).toHaveLength(1);
      expect(result[0].memoryType).toBe(type);
    });
  });

  it("returns empty array when all candidates are invalid", () => {
    const response = JSON.stringify([
      {
        content: "Missing fields",
        memoryType: "decision",
      },
      {
        content: "Invalid type",
        summary: "Summary",
        memoryType: "not_valid",
        category: "project",
        confidence: 0.8,
        priority: 5,
      },
    ]);

    const result = parseExtractionResponse(response);
    expect(result).toEqual([]);
  });

  // Property-based tests
  describe("properties", () => {
    const memoryTypeArb = fc.constantFrom<MemoryType>(
      "architecture",
      "decision",
      "pattern",
      "gotcha",
      "context",
      "progress",
      "code_description",
      "code"
    );

    const categoryArb = fc.constantFrom<"project" | "global">(
      "project",
      "global"
    );

    const validMemoryArb = fc.record({
      content: fc.string({ minLength: 1 }),
      summary: fc.string({ minLength: 1 }),
      memoryType: memoryTypeArb,
      category: categoryArb,
      confidence: fc.double({ min: 0, max: 1, noNaN: true }),
      priority: fc.integer({ min: 1, max: 10 }),
    });

    it("always returns array", () => {
      fc.assert(
        fc.property(fc.array(validMemoryArb), (memories) => {
          const response = JSON.stringify(memories);
          const result = parseExtractionResponse(response);
          expect(Array.isArray(result)).toBe(true);
        })
      );
    });

    it("all parsed memories have valid types", () => {
      fc.assert(
        fc.property(fc.array(validMemoryArb), (memories) => {
          const response = JSON.stringify(memories);
          const result = parseExtractionResponse(response);

          result.forEach((memory) => {
            expect(memory.memoryType).toMatch(
              /^(architecture|decision|pattern|gotcha|context|progress|code_description|code)$/
            );
          });
        })
      );
    });

    it("all parsed memories have valid confidence range", () => {
      fc.assert(
        fc.property(fc.array(validMemoryArb), (memories) => {
          const response = JSON.stringify(memories);
          const result = parseExtractionResponse(response);

          result.forEach((memory) => {
            expect(memory.confidence).toBeGreaterThanOrEqual(0);
            expect(memory.confidence).toBeLessThanOrEqual(1);
          });
        })
      );
    });

    it("all parsed memories have valid priority range", () => {
      fc.assert(
        fc.property(fc.array(validMemoryArb), (memories) => {
          const response = JSON.stringify(memories);
          const result = parseExtractionResponse(response);

          result.forEach((memory) => {
            expect(memory.priority).toBeGreaterThanOrEqual(1);
            expect(memory.priority).toBeLessThanOrEqual(10);
            expect(Number.isInteger(memory.priority)).toBe(true);
          });
        })
      );
    });
  });
});

describe("buildEmbeddingText", () => {
  it("includes memory type prefix (FR-108)", () => {
    const memory: MemoryCandidate = {
      content: "Full content",
      summary: "Test summary",
      memoryType: "decision",
      category: "project",
      confidence: 0.8,
      priority: 5,
    };

    const result = buildEmbeddingText(memory, "test-project");

    expect(result).toBe("[decision] [project:test-project] Test summary");
  });

  it("includes project name in prefix (FR-108)", () => {
    const memory: MemoryCandidate = {
      content: "Full content",
      summary: "Test summary",
      memoryType: "pattern",
      category: "global",
      confidence: 0.9,
      priority: 8,
    };

    const result = buildEmbeddingText(memory, "my-app");

    expect(result).toContain("[project:my-app]");
  });

  it("formats all memory types correctly", () => {
    const memoryTypes: MemoryType[] = [
      "architecture",
      "decision",
      "pattern",
      "gotcha",
      "context",
      "progress",
      "code_description",
      "code",
    ];

    memoryTypes.forEach((type) => {
      const memory: MemoryCandidate = {
        content: "Content",
        summary: "Summary",
        memoryType: type,
        category: "project",
        confidence: 0.8,
        priority: 5,
      };

      const result = buildEmbeddingText(memory, "test");
      expect(result).toMatch(
        new RegExp(`^\\[${type}\\] \\[project:test\\] Summary$`)
      );
    });
  });

  // Property-based tests
  describe("properties", () => {
    const memoryTypeArb = fc.constantFrom<MemoryType>(
      "architecture",
      "decision",
      "pattern",
      "gotcha",
      "context",
      "progress",
      "code_description",
      "code"
    );

    const categoryArb = fc.constantFrom<"project" | "global">(
      "project",
      "global"
    );

    const memoryArb = fc.record({
      content: fc.string({ minLength: 1 }),
      summary: fc.string({ minLength: 1 }),
      memoryType: memoryTypeArb,
      category: categoryArb,
      confidence: fc.double({ min: 0, max: 1 }),
      priority: fc.integer({ min: 1, max: 10 }),
    });

    it("always starts with memory type prefix", () => {
      fc.assert(
        fc.property(memoryArb, fc.string({ minLength: 1 }), (memory, project) => {
          const result = buildEmbeddingText(memory, project);
          expect(result).toMatch(/^\[.*?\] /);
          expect(result).toContain(`[${memory.memoryType}]`);
        })
      );
    });

    it("always includes project name", () => {
      fc.assert(
        fc.property(memoryArb, fc.string({ minLength: 1 }), (memory, project) => {
          const result = buildEmbeddingText(memory, project);
          expect(result).toContain(`[project:${project}]`);
        })
      );
    });

    it("always includes summary at the end", () => {
      fc.assert(
        fc.property(memoryArb, fc.string({ minLength: 1 }), (memory, project) => {
          const result = buildEmbeddingText(memory, project);
          expect(result).toEndWith(memory.summary);
        })
      );
    });

    it("format matches expected pattern", () => {
      fc.assert(
        fc.property(memoryArb, fc.string({ minLength: 1 }), (memory, project) => {
          const result = buildEmbeddingText(memory, project);
          const expected = `[${memory.memoryType}] [project:${project}] ${memory.summary}`;
          expect(result).toBe(expected);
        })
      );
    });
  });
});
