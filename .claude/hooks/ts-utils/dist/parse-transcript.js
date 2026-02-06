#!/usr/bin/env node

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
export {
  parseTranscript
};
