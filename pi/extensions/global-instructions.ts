/**
 * Global Instructions Extension
 *
 * Auto-loads a global instructions file and injects it into every session's
 * system prompt. Checks (in order of priority):
 *
 *   1. ~/.pi/agent/INSTRUCTIONS.md   (pi-native path)
 *   2. ~/.claude/CLAUDE.md            (Claude Code compat)
 *   3. ~/CLAUDE.md                    (fallback)
 *
 * The first file found is used. Its contents are appended to the system
 * prompt via `before_agent_start`.
 *
 * Additionally loads project-local equivalents:
 *   1. .pi/INSTRUCTIONS.md
 *   2. CLAUDE.md (project root)
 *
 * Both global and project-local are concatenated (global first).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const GLOBAL_PATHS = [
  join(homedir(), ".pi", "agent", "INSTRUCTIONS.md"),
  join(homedir(), ".claude", "CLAUDE.md"),
  join(homedir(), "CLAUDE.md"),
];

const PROJECT_PATHS = [
  ".pi/INSTRUCTIONS.md",
  "CLAUDE.md",
];

function findFirst(paths: string[]): string | null {
  for (const p of paths) {
    if (existsSync(p)) return p;
  }
  return null;
}

function loadFile(path: string): string | null {
  try {
    const content = readFileSync(path, "utf-8").trim();
    return content.length > 0 ? content : null;
  } catch {
    return null;
  }
}

export default function (pi: ExtensionAPI) {
  let globalInstructions: string | null = null;
  let globalPath: string | null = null;

  // Load global instructions once at startup
  globalPath = findFirst(GLOBAL_PATHS);
  if (globalPath) {
    globalInstructions = loadFile(globalPath);
  }

  pi.on("session_start", async (_event, ctx) => {
    if (globalPath && globalInstructions) {
      ctx.ui.setStatus("instructions", `📋 ${globalPath}`);
    }
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const parts: string[] = [];

    // Global instructions
    if (globalInstructions) {
      parts.push(`# Global Instructions (from ${globalPath})\n\n${globalInstructions}`);
    }

    // Project-local instructions
    const projectPaths = PROJECT_PATHS.map((p) => join(ctx.cwd, p));
    const projectPath = findFirst(projectPaths);
    if (projectPath) {
      const projectInstructions = loadFile(projectPath);
      if (projectInstructions) {
        parts.push(`# Project Instructions (from ${projectPath})\n\n${projectInstructions}`);
      }
    }

    if (parts.length === 0) return;

    const combined = parts.join("\n\n---\n\n");

    return {
      systemPrompt: event.systemPrompt + "\n\n" + combined,
    };
  });
}
