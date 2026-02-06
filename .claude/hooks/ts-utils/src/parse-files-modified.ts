#!/usr/bin/env node
/**
 * Extract Write/Edit file paths from a Claude Code JSONL transcript
 * Returns newline-separated list of absolute file paths modified by agent
 *
 * Usage: node parse-files-modified.js <transcript-path>
 */

import { readFileSync } from "node:fs";
import { parseJsonl, getContentBlocks } from "./types.js";

const FILE_MODIFYING_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);

export function parseFilesModified(content: string): string[] {
  const files = new Set<string>();

  for (const line of parseJsonl(content)) {
    for (const block of getContentBlocks(line)) {
      if (block.type !== "tool_use") continue;

      const name = block.name ?? "";
      if (!FILE_MODIFYING_TOOLS.has(name)) continue;

      const input = block.input as Record<string, unknown> | undefined;
      const filePath = input?.file_path;

      if (typeof filePath === "string") {
        files.add(filePath);
      }
    }
  }

  return [...files].sort();
}

// CLI entry point
if (process.argv[1]?.endsWith("parse-files-modified.js")) {
  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    process.exit(0);
  }

  try {
    const content = readFileSync(transcriptPath, "utf-8");
    const result = parseFilesModified(content);
    console.log(result.join("\n"));
  } catch {
    process.exit(0);
  }
}
