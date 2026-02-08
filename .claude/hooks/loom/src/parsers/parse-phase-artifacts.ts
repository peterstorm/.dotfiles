/**
 * Extract spec_file and plan_file paths from phase agent transcripts
 * Looks for Write tool calls to .claude/specs/ and .claude/plans/
 */

import { parseJsonl, getContentBlocks } from "./types";

export interface PhaseArtifacts {
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

      if (filePath.includes(".claude/specs/") && filePath.endsWith(".md")) {
        if (!artifacts.spec_file || filePath.length > artifacts.spec_file.length) {
          artifacts.spec_file = filePath;
        }
      }

      if (filePath.includes(".claude/plans/") && filePath.endsWith(".md")) {
        if (!artifacts.plan_file || filePath.length > artifacts.plan_file.length) {
          artifacts.plan_file = filePath;
        }
      }
    }
  }

  return artifacts;
}
