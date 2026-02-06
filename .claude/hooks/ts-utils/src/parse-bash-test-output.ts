#!/usr/bin/env node
/**
 * Extract test output ONLY from Bash tool_use/tool_result pairs in JSONL transcript
 * Anti-spoofing: ignores free text — only returns output from actual test commands
 *
 * Usage: node parse-bash-test-output.js <transcript-path>
 */

import { readFileSync } from "node:fs";
import { parseJsonl, getContentBlocks, type ContentBlock } from "./types.js";

const TEST_PATTERNS = [
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
  "make check",
];

function isTestCommand(cmd: string): boolean {
  const cmdLower = cmd.toLowerCase().trim();
  return TEST_PATTERNS.some((p) => cmdLower.includes(p));
}

function extractToolResultContent(block: ContentBlock): string[] {
  const results: string[] = [];
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

export function parseBashTestOutput(content: string): string {
  const pendingToolIds = new Set<string>();
  const results: string[] = [];

  for (const line of parseJsonl(content)) {
    for (const block of getContentBlocks(line)) {
      // Detect Bash tool_use with test command
      if (block.type === "tool_use" && block.name === "Bash") {
        const input = block.input as Record<string, unknown> | undefined;
        const cmd = (input?.command as string) ?? "";

        if (isTestCommand(cmd) && block.id) {
          pendingToolIds.add(block.id);
        }
      }

      // Collect tool_result for matched tool_use IDs
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

// CLI entry point
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
