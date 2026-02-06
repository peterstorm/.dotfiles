#!/usr/bin/env node
/**
 * Extract plain text from a Claude Code JSONL transcript file
 * Parses assistant messages, tool results, and nested content blocks
 *
 * Usage: node parse-transcript.js <transcript-path>
 */

import { readFileSync } from "node:fs";
import { parseJsonl, getContentBlocks, type ContentBlock } from "./types.js";

function extractText(block: ContentBlock): string[] {
  const texts: string[] = [];

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

export function parseTranscript(content: string): string {
  const texts: string[] = [];

  for (const line of parseJsonl(content)) {
    const msgContent = line.message?.content;

    // Handle string content directly
    if (typeof msgContent === "string") {
      texts.push(msgContent);
      continue;
    }

    // Handle content blocks
    for (const block of getContentBlocks(line)) {
      texts.push(...extractText(block));
    }
  }

  return texts.join("\n");
}

// CLI entry point
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
    // File not found or read error - silent exit like Python version
    process.exit(0);
  }
}
