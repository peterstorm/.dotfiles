import { describe, it } from "node:test";
import assert from "node:assert";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { parseTranscript } from "./parse-transcript.js";
import { parseFilesModified } from "./parse-files-modified.js";
import { parseBashTestOutput } from "./parse-bash-test-output.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(__dirname, "..", "src", "fixtures");

describe("parseTranscript", () => {
  it("extracts text from string content", () => {
    const content = '{"message":{"content":"Hello world"}}';
    const result = parseTranscript(content);
    assert.ok(result.includes("Hello world"));
  });

  it("extracts text from content blocks", () => {
    const content =
      '{"message":{"content":[{"type":"text","text":"Block text"}]}}';
    const result = parseTranscript(content);
    assert.ok(result.includes("Block text"));
  });

  it("extracts tool_result content", () => {
    const content =
      '{"message":{"content":[{"type":"tool_result","content":"Result text"}]}}';
    const result = parseTranscript(content);
    assert.ok(result.includes("Result text"));
  });
});

describe("parseFilesModified", () => {
  it("extracts Write file paths", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/test.ts"}}]}}';
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, ["/tmp/test.ts"]);
  });

  it("extracts Edit file paths", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/other.ts"}}]}}';
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, ["/tmp/other.ts"]);
  });

  it("ignores non-file-modifying tools", () => {
    const content =
      '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}';
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, []);
  });

  it("deduplicates files", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/test.ts"}}]}}',
      '{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/test.ts"}}]}}',
    ].join("\n");
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, ["/tmp/test.ts"]);
  });
});

describe("parseBashTestOutput", () => {
  it("extracts npm test output", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"npm test"}}]}}',
      '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Tests passed"}]}}',
    ].join("\n");
    const result = parseBashTestOutput(content);
    assert.ok(result.includes("Tests passed"));
  });

  it("ignores non-test Bash commands", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"ls -la"}}]}}',
      '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt"}]}}',
    ].join("\n");
    const result = parseBashTestOutput(content);
    assert.strictEqual(result, "");
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
      assert.ok(result.includes("OK"), `Failed for: ${cmd}`);
    }
  });
});
