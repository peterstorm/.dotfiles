// src/tests.ts
import { describe, it } from "node:test";
import assert from "node:assert";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

// src/parse-transcript.ts
import { readFileSync } from "node:fs";

// src/types.ts
function* parseJsonl(content) {
  for (const line of content.split("\n")) {
    if (!line.trim())
      continue;
    try {
      yield JSON.parse(line);
    } catch {
    }
  }
}
function getContentBlocks(line) {
  const content = line.message?.content;
  if (!content)
    return [];
  if (typeof content === "string")
    return [];
  return content;
}

// src/parse-transcript.ts
function extractText(block) {
  const texts = [];
  if (block.type === "text" && block.text) {
    texts.push(block.text);
  } else if (block.type === "tool_result") {
    const content = block.content;
    if (typeof content === "string") {
      texts.push(content);
    } else if (Array.isArray(content)) {
      for (const sub of content) {
        if (sub.type === "text" && sub.text) {
          texts.push(sub.text);
        }
      }
    }
  }
  return texts;
}
function parseTranscript(content) {
  const texts = [];
  for (const line of parseJsonl(content)) {
    const msgContent = line.message?.content;
    if (typeof msgContent === "string") {
      texts.push(msgContent);
      continue;
    }
    for (const block of getContentBlocks(line)) {
      texts.push(...extractText(block));
    }
  }
  return texts.join("\n");
}
if (process.argv[1]?.endsWith("parse-transcript.js")) {
  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    process.exit(0);
  }
  try {
    const content = readFileSync(transcriptPath, "utf-8");
    const result = parseTranscript(content);
    console.log(result);
  } catch {
    process.exit(0);
  }
}

// src/parse-files-modified.ts
import { readFileSync as readFileSync2 } from "node:fs";
var FILE_MODIFYING_TOOLS = /* @__PURE__ */ new Set(["Write", "Edit", "MultiEdit"]);
function parseFilesModified(content) {
  const files = /* @__PURE__ */ new Set();
  for (const line of parseJsonl(content)) {
    for (const block of getContentBlocks(line)) {
      if (block.type !== "tool_use")
        continue;
      const name = block.name ?? "";
      if (!FILE_MODIFYING_TOOLS.has(name))
        continue;
      const input = block.input;
      const filePath = input?.file_path;
      if (typeof filePath === "string") {
        files.add(filePath);
      }
    }
  }
  return [...files].sort();
}
if (process.argv[1]?.endsWith("parse-files-modified.js")) {
  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    process.exit(0);
  }
  try {
    const content = readFileSync2(transcriptPath, "utf-8");
    const result = parseFilesModified(content);
    console.log(result.join("\n"));
  } catch {
    process.exit(0);
  }
}

// src/parse-bash-test-output.ts
import { readFileSync as readFileSync3 } from "node:fs";
var TEST_PATTERNS = [
  "mvn test",
  "mvn verify",
  "mvn -pl",
  "mvnw test",
  "mvnw verify",
  "./gradlew test",
  "./gradlew check",
  "gradle test",
  "gradle check",
  "npm test",
  "npm run test",
  "npx vitest",
  "npx jest",
  "yarn test",
  "pnpm test",
  "bun test",
  "pytest",
  "python -m pytest",
  "python3 -m pytest",
  "cargo test",
  "go test",
  "dotnet test",
  "mix test",
  "make test",
  "make check"
];
function isTestCommand(cmd) {
  const cmdLower = cmd.toLowerCase().trim();
  return TEST_PATTERNS.some((p) => cmdLower.includes(p));
}
function extractToolResultContent(block) {
  const results = [];
  const content = block.content;
  if (typeof content === "string") {
    results.push(content);
  } else if (Array.isArray(content)) {
    for (const sub of content) {
      if (sub.type === "text" && sub.text) {
        results.push(sub.text);
      }
    }
  }
  return results;
}
function parseBashTestOutput(content) {
  const pendingToolIds = /* @__PURE__ */ new Set();
  const results = [];
  for (const line of parseJsonl(content)) {
    for (const block of getContentBlocks(line)) {
      if (block.type === "tool_use" && block.name === "Bash") {
        const input = block.input;
        const cmd = input?.command ?? "";
        if (isTestCommand(cmd) && block.id) {
          pendingToolIds.add(block.id);
        }
      }
      if (block.type === "tool_result") {
        const toolUseId = block.tool_use_id ?? "";
        if (pendingToolIds.has(toolUseId)) {
          results.push(...extractToolResultContent(block));
        }
      }
    }
  }
  return results.join("\n");
}
if (process.argv[1]?.endsWith("parse-bash-test-output.js")) {
  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    process.exit(0);
  }
  try {
    const content = readFileSync3(transcriptPath, "utf-8");
    const result = parseBashTestOutput(content);
    console.log(result);
  } catch {
    process.exit(0);
  }
}

// src/tests.ts
var __dirname = dirname(fileURLToPath(import.meta.url));
var fixturesDir = join(__dirname, "..", "src", "fixtures");
describe("parseTranscript", () => {
  it("extracts text from string content", () => {
    const content = '{"message":{"content":"Hello world"}}';
    const result = parseTranscript(content);
    assert.ok(result.includes("Hello world"));
  });
  it("extracts text from content blocks", () => {
    const content = '{"message":{"content":[{"type":"text","text":"Block text"}]}}';
    const result = parseTranscript(content);
    assert.ok(result.includes("Block text"));
  });
  it("extracts tool_result content", () => {
    const content = '{"message":{"content":[{"type":"tool_result","content":"Result text"}]}}';
    const result = parseTranscript(content);
    assert.ok(result.includes("Result text"));
  });
});
describe("parseFilesModified", () => {
  it("extracts Write file paths", () => {
    const content = '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/test.ts"}}]}}';
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, ["/tmp/test.ts"]);
  });
  it("extracts Edit file paths", () => {
    const content = '{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/other.ts"}}]}}';
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, ["/tmp/other.ts"]);
  });
  it("ignores non-file-modifying tools", () => {
    const content = '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}';
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, []);
  });
  it("deduplicates files", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/test.ts"}}]}}',
      '{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/test.ts"}}]}}'
    ].join("\n");
    const result = parseFilesModified(content);
    assert.deepStrictEqual(result, ["/tmp/test.ts"]);
  });
});
describe("parseBashTestOutput", () => {
  it("extracts npm test output", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"npm test"}}]}}',
      '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Tests passed"}]}}'
    ].join("\n");
    const result = parseBashTestOutput(content);
    assert.ok(result.includes("Tests passed"));
  });
  it("ignores non-test Bash commands", () => {
    const content = [
      '{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"ls -la"}}]}}',
      '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt"}]}}'
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
      "npx vitest"
    ];
    for (const cmd of testCases) {
      const content = [
        `{"message":{"content":[{"type":"tool_use","name":"Bash","id":"t1","input":{"command":"${cmd}"}}]}}`,
        '{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"OK"}]}}'
      ].join("\n");
      const result = parseBashTestOutput(content);
      assert.ok(result.includes("OK"), `Failed for: ${cmd}`);
    }
  });
});
