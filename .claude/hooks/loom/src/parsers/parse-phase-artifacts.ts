/**
 * Extract spec_file and plan_file paths from phase agent transcripts
 * Looks for Write tool calls to .claude/specs/ and .claude/plans/
 */

import { parseJsonl, getContentBlocks } from "./types";

export interface PhaseArtifacts {
  spec_file?: string;
  plan_file?: string;
}

/**
 * @param specDir - If provided, only accept spec files under this directory
 */
export function parsePhaseArtifacts(content: string, specDir?: string | null): PhaseArtifacts {
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
        if (specDir && !filePath.includes(specDir)) continue;
        // Prefer spec.md over other .md files; among same priority prefer deeper path
        const isSpec = filePath.endsWith("/spec.md");
        const prevIsSpec = artifacts.spec_file?.endsWith("/spec.md") ?? false;
        if (!artifacts.spec_file || (isSpec && !prevIsSpec)
            || (isSpec === prevIsSpec && filePath.length > artifacts.spec_file!.length)) {
          artifacts.spec_file = filePath;
        }
      }

      if (filePath.includes(".claude/plans/") && filePath.endsWith(".md")) {
        const isPlan = filePath.endsWith("/plan.md");
        const prevIsPlan = artifacts.plan_file?.endsWith("/plan.md") ?? false;
        if (!artifacts.plan_file || (isPlan && !prevIsPlan)
            || (isPlan === prevIsPlan && filePath.length > artifacts.plan_file!.length)) {
          artifacts.plan_file = filePath;
        }
      }
    }
  }

  return artifacts;
}
