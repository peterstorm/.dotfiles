#!/usr/bin/env node

// src/parse-files-modified.ts
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

// src/parse-files-modified.ts
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
    const content = readFileSync(transcriptPath, "utf-8");
    const result = parseFilesModified(content);
    console.log(result.join("\n"));
  } catch {
    process.exit(0);
  }
}
export {
  parseFilesModified
};
