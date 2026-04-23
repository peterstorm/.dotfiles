/**
 * loom-guard: Plugin that enforces loom constraints.
 *
 * When loom state is active (.loom/state.json exists):
 * 1. Blocks direct file edits (Write/Edit/MultiEdit) from the orchestrator
 *    (subagents spawned via loom tools CAN edit — they run in their own sessions)
 * 2. Blocks the built-in Task tool entirely (must use loom-impl/loom-review/loom-phase)
 * 3. Blocks bash commands that would write to the state file
 *
 * This is Layer 1 of the three-layer enforcement model.
 * Throwing from tool.execute.before blocks the tool call.
 */

import type { Plugin } from "@opencode-ai/plugin"
import { existsSync } from "node:fs"
import { STATE_FILE_PATTERNS, WRITE_PATTERNS } from "../tools/lib/config"

/** Check if loom is active (state file exists) */
function isLoomActive(): boolean {
  // Check common locations
  if (existsSync(".loom/state.json")) return true
  try {
    const { execSync } = require("node:child_process")
    const root = execSync("git rev-parse --show-toplevel", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim()
    if (root && existsSync(`${root}/.loom/state.json`)) return true
  } catch {
    // Not in a git repo
  }
  return false
}

export const LoomGuard: Plugin = async ({ project, client, $, directory, worktree }) => {
  return {
    "tool.execute.before": async (input, output) => {
      // Only enforce when loom is active
      if (!isLoomActive()) return

      const toolName = input.tool

      // --- Block 1: Direct file edits from orchestrator ---
      // The orchestrator session MUST NOT edit files directly.
      // Subagents spawned by loom tools run in separate sessions and are not affected.
      if (toolName === "write" || toolName === "edit" || toolName === "multi_edit" ||
          toolName === "Write" || toolName === "Edit" || toolName === "MultiEdit") {
        throw new Error(
          "BLOCKED by loom-guard: Direct file edits are not allowed during loom orchestration. " +
          "Use loom-impl to spawn implementation agents that can edit files."
        )
      }

      // --- Block 2: Built-in Task tool ---
      // During loom, all agent spawning must go through loom tools
      // (loom-phase, loom-impl, loom-review) which handle validation and state management.
      if (toolName === "task" || toolName === "Task") {
        throw new Error(
          "BLOCKED by loom-guard: The Task tool is disabled during loom orchestration. " +
          "Use loom-phase (for phase agents), loom-impl (for implementation), " +
          "or loom-review (for reviews) instead."
        )
      }

      // --- Block 3: Bash commands that modify state file ---
      if (toolName === "bash" || toolName === "Bash") {
        const command = (output.args as Record<string, unknown>)?.command
        if (typeof command === "string") {
          // Check if command references state file AND contains write patterns
          if (STATE_FILE_PATTERNS.test(command) && WRITE_PATTERNS.test(command)) {
            throw new Error(
              "BLOCKED by loom-guard: Bash commands cannot modify the loom state file. " +
              "State is managed exclusively through loom tools."
            )
          }
        }
      }
    },
  }
}
