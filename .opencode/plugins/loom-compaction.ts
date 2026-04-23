/**
 * loom-compaction: Plugin that injects loom state context during compaction.
 *
 * When the session compacts (context window fills up), this plugin injects
 * the current loom state, phase info, and wave status so the orchestrator
 * doesn't lose track of where it is in the pipeline.
 *
 * Uses the `experimental.session.compacting` event to push context.
 */

import type { Plugin } from "@opencode-ai/plugin"
import { existsSync, readFileSync } from "node:fs"
import { STATE_PATH } from "../tools/lib/config"
import type { TaskGraph, Task } from "../tools/lib/types"

/** Load loom state if it exists, return null otherwise */
function loadState(): TaskGraph | null {
  try {
    if (!existsSync(STATE_PATH)) return null
    const raw = readFileSync(STATE_PATH, "utf-8")
    return JSON.parse(raw) as TaskGraph
  } catch {
    return null
  }
}

/** Format task status summary */
function formatTasks(tasks: readonly Task[], currentWave?: number): string {
  if (tasks.length === 0) return "No tasks yet (pre-decompose phase)."

  const waveGroups = new Map<number, Task[]>()
  for (const t of tasks) {
    const list = waveGroups.get(t.wave) ?? []
    list.push(t)
    waveGroups.set(t.wave, list)
  }

  const lines: string[] = []
  for (const [wave, waveTasks] of [...waveGroups.entries()].sort((a, b) => a[0] - b[0])) {
    const marker = wave === currentWave ? " ← CURRENT" : ""
    lines.push(`  Wave ${wave}${marker}:`)
    for (const t of waveTasks) {
      const status = t.status === "completed" ? "✓" :
        t.status === "implemented" ? "→" :
        t.status === "failed" ? "✗" : "○"
      const review = t.review_status ? ` [review: ${t.review_status}]` : ""
      const tests = t.tests_passed !== undefined ? ` [tests: ${t.tests_passed ? "pass" : "fail"}]` : ""
      lines.push(`    [${status}] ${t.id}: ${t.description} (${t.agent})${tests}${review}`)
    }
  }
  return lines.join("\n")
}

/** Build compaction context string */
function buildCompactionContext(state: TaskGraph): string {
  const lines: string[] = [
    "=== LOOM ORCHESTRATION STATE (injected at compaction) ===",
    "",
    `Phase: ${state.current_phase}`,
    `Skipped phases: ${state.skipped_phases.length > 0 ? state.skipped_phases.join(", ") : "none"}`,
    "",
  ]

  // Phase artifacts
  const artifactEntries = Object.entries(state.phase_artifacts)
  if (artifactEntries.length > 0) {
    lines.push("Phase artifacts:")
    for (const [phase, status] of artifactEntries) {
      lines.push(`  ${phase}: ${status ?? "pending"}`)
    }
    lines.push("")
  }

  // Spec / plan files
  if (state.spec_file) lines.push(`Spec file: ${state.spec_file}`)
  if (state.plan_file) lines.push(`Plan file: ${state.plan_file}`)
  if (state.plan_title) lines.push(`Plan title: ${state.plan_title}`)
  if (state.github_issue) lines.push(`GitHub issue: #${state.github_issue}`)
  if (state.spec_file || state.plan_file) lines.push("")

  // Current wave info
  if (state.current_phase === "execute") {
    lines.push(`Current wave: ${state.current_wave ?? "?"}`)
    lines.push("")
  }

  // Tasks
  lines.push("Tasks:")
  lines.push(formatTasks(state.tasks, state.current_wave))
  lines.push("")

  // Wave gates
  const gateEntries = Object.entries(state.wave_gates)
  if (gateEntries.length > 0) {
    lines.push("Wave gates:")
    for (const [wave, gate] of gateEntries) {
      const status = gate.blocked ? "BLOCKED" :
        gate.impl_complete && gate.tests_passed && gate.reviews_complete ? "PASSED" : "PENDING"
      lines.push(`  Wave ${wave}: ${status} (impl: ${gate.impl_complete}, tests: ${gate.tests_passed}, reviews: ${gate.reviews_complete})`)
    }
    lines.push("")
  }

  // Spec check
  if (state.spec_check) {
    lines.push(`Spec check: wave ${state.spec_check.wave}, verdict: ${state.spec_check.verdict}`)
    if (state.spec_check.critical_count) {
      lines.push(`  Critical findings: ${state.spec_check.critical_count}`)
    }
    lines.push("")
  }

  lines.push("--- Use loom-state-query for full details. Use loom-phase/loom-impl/loom-review/loom-gate/loom-control to continue. ---")
  lines.push("=== END LOOM STATE ===")

  return lines.join("\n")
}

export const LoomCompaction: Plugin = async ({ project, client, $, directory, worktree }) => {
  return {
    "experimental.session.compacting": async (input, output) => {
      const state = loadState()
      if (!state) return // No loom active, nothing to inject

      output.context.push(buildCompactionContext(state))
    },
  }
}
