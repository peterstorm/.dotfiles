import { describe, it, expect } from "vitest";

import { parseTranscript } from "../../src/parsers/parse-transcript";
import { parseFilesModified } from "../../src/parsers/parse-files-modified";
import { parseBashTestOutput } from "../../src/parsers/parse-bash-test-output";
import { parsePhaseArtifacts } from "../../src/parsers/parse-phase-artifacts";

describe("parseTranscript", () => {
  it("extracts text from string content", () => {
    const content = '{"message":{"content":"Hello world"}}';
    const result = parseTranscript(content);
    expect(result).toContain("Hello world");
  });

  it("extracts text from content blocks", () => {
    const content =
      '{"message":{"content":[{"type":"text","text":"Block text"}]}}';
    const result = parseTranscript(content);
    expect(result).toContain("Block text");
  });

  it("extracts tool_result content", () => {
    const content =
      '{"message":{"content":[{"type":"tool_result","content":"Result text"}]}}';
    const result = parseTranscript(content);
    expect(result).toContain("Result text");
  });
});

describe("parseFilesModified", () => {
  it("extracts Write file paths", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/test.ts"}}]}}';
    const result = parseFilesModified(content);
    expect(result).toEqual(["/tmp/test.ts"]);
  });

  it("extracts Edit file paths", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/other.ts"}}]}}';
    const result = parseFilesModified(content);
    expect(result).toEqual(["/tmp/other.ts"]);
  });

  it("ignores non-file-modifying tools", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}';
    const result = parseFilesModified(content);
    expect(result).toEqual([]);
  });

  it("deduplicates files", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/test.ts"}}]}}',
      '{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/test.ts"}}]}}',
    ].join("\n");
    const result = parseFilesModified(content);
    expect(result).toEqual(["/tmp/test.ts"]);
  });
});

describe("parseBashTestOutput", () => {
  it("extracts npm test output", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"npm test"}}]}}',
      '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Tests passed"}]}}',
    ].join("\n");
    const result = parseBashTestOutput(content);
    expect(result).toContain("Tests passed");
  });

  it("ignores non-test Bash commands", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"ls -la"}}]}}',
      '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt"}]}}',
    ].join("\n");
    const result = parseBashTestOutput(content);
    expect(result).toBe("");
  });

  it("matches various test runners", () => {
    const testCases = [
      "pytest",
      "cargo test",
      "go test ./...",
      "mvn test",
      "./gradlew test",
      "npx vitest",
    ];

    for (const cmd of testCases) {
      const content = [
        `{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"${cmd}"}}]}}`,
        '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"OK"}]}}',
      ].join("\n");
      const result = parseBashTestOutput(content);
      expect(result).toContain("OK");
    }
  });
});

describe("parsePhaseArtifacts", () => {
  it("extracts spec_file from Write to .claude/specs/", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/.claude/specs/2025-01-15-auth/spec.md"}}]}}';
    const result = parsePhaseArtifacts(content);
    expect(result.spec_file).toBe(
      "/project/.claude/specs/2025-01-15-auth/spec.md"
    );
    expect(result.plan_file).toBeUndefined();
  });

  it("extracts plan_file from Write to .claude/plans/", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/.claude/plans/2025-01-15-auth.md"}}]}}';
    const result = parsePhaseArtifacts(content);
    expect(result.plan_file).toBe(
      "/project/.claude/plans/2025-01-15-auth.md"
    );
    expect(result.spec_file).toBeUndefined();
  });

  it("extracts both spec_file and plan_file", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/.claude/specs/2025-01-15-auth/spec.md"}}]}}',
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/.claude/plans/2025-01-15-auth.md"}}]}}',
    ].join("\n");
    const result = parsePhaseArtifacts(content);
    expect(result.spec_file).toBe(
      "/project/.claude/specs/2025-01-15-auth/spec.md"
    );
    expect(result.plan_file).toBe(
      "/project/.claude/plans/2025-01-15-auth.md"
    );
  });

  it("ignores Write to non-artifact paths", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/src/auth.ts"}}]}}';
    const result = parsePhaseArtifacts(content);
    expect(result.spec_file).toBeUndefined();
    expect(result.plan_file).toBeUndefined();
  });

  it("ignores non-.md files", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/.claude/specs/data.json"}}]}}';
    const result = parsePhaseArtifacts(content);
    expect(result.spec_file).toBeUndefined();
  });

  it("prefers deeper spec path", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/.claude/specs/spec.md"}}]}}',
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/project/.claude/specs/2025-01-15-auth/spec.md"}}]}}',
    ].join("\n");
    const result = parsePhaseArtifacts(content);
    expect(result.spec_file).toBe(
      "/project/.claude/specs/2025-01-15-auth/spec.md"
    );
  });

  it("handles filePath variant", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"filePath":"/project/.claude/specs/2025-01-15-auth/spec.md"}}]}}';
    const result = parsePhaseArtifacts(content);
    expect(result.spec_file).toBe(
      "/project/.claude/specs/2025-01-15-auth/spec.md"
    );
  });

  it("returns empty object for empty transcript", () => {
    const result = parsePhaseArtifacts("");
    expect(result).toEqual({});
  });

  it("returns empty object for transcript with no Write calls", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}';
    const result = parsePhaseArtifacts(content);
    expect(result).toEqual({});
  });
});
