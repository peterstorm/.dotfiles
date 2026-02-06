#!/usr/bin/env node
/**
 * Extract spec_file and plan_file paths from phase agent transcripts
 * Looks for Write tool calls to .claude/specs/ and .claude/plans/
 *
 * Usage: node parse-phase-artifacts.js <transcript-path>
 * Output: JSON { spec_file?: string, plan_file?: string }
 */

import { readFileSync } from "node:fs";
import { parseJsonl, getContentBlocks } from "./types.js";

interface PhaseArtifacts {
  spec_file?: string;
  plan_file?: string;
}

export function parsePhaseArtifacts(content: string): PhaseArtifacts {
  const artifacts: PhaseArtifacts = {};

  for (const line of parseJsonl(content)) {
    for (const block of getContentBlocks(line)) {
      if (block.type !== "tool_use") continue;

      const name = block.name ?? "";
      if (name !== "Write") continue;

      const input = block.input as Record<string, unknown> | undefined;
      const filePath = input?.file_path ?? input?.filePath;

      if (typeof filePath !== "string") continue;

      // Spec file: .claude/specs/**/*.md
      if (filePath.includes(".claude/specs/") && filePath.endsWith(".md")) {
        // Prefer the most specific path (deeper in the tree)
        if (
          !artifacts.spec_file ||
          filePath.length > artifacts.spec_file.length
        ) {
          artifacts.spec_file = filePath;
        }
      }

      // Plan file: .claude/plans/**/*.md
      if (filePath.includes(".claude/plans/") && filePath.endsWith(".md")) {
        if (
          !artifacts.plan_file ||
          filePath.length > artifacts.plan_file.length
        ) {
          artifacts.plan_file = filePath;
        }
      }
    }
  }

  return artifacts;
}

// CLI entry point
if (/parse-phase-artifacts\.[jt]s$/.test(process.argv[1] ?? "")) {
  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    console.log("{}");
    process.exit(0);
  }

  try {
    const content = readFileSync(transcriptPath, "utf-8");
    const result = parsePhaseArtifacts(content);
    console.log(JSON.stringify(result));
  } catch {
    console.log("{}");
    process.exit(0);
  }
}
