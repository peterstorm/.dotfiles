#!/usr/bin/env node

// src/parse-bash-test-output.ts
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

// src/parse-bash-test-output.ts
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
    const content = readFileSync(transcriptPath, "utf-8");
    const result = parseBashTestOutput(content);
    console.log(result);
  } catch {
    process.exit(0);
  }
}
export {
  parseBashTestOutput
};
