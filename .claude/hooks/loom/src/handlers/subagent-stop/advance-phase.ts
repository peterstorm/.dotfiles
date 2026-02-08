/**
 * Advance current_phase when phase agents complete.
 * Extracts and stores phase artifacts from transcript.
 *
 * Phases: brainstorm → specify → clarify → architecture → decompose → execute
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { match } from "ts-pattern";
import type { HookHandler, SubagentStopInput, Phase, TaskGraph } from "../../types";
import { PHASE_AGENT_MAP, CLARIFY_THRESHOLD } from "../../config";
import { StateManager } from "../../state-manager";
import { parsePhaseArtifacts } from "../../parsers/parse-phase-artifacts";

/** Recursively search for a file by name under a directory */
export function findFile(dir: string, filename: string): string | null {
  if (!existsSync(dir)) return null;
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isFile() && entry.name === filename) return join(dir, entry.name);
      if (entry.isDirectory()) {
        const found = findFile(join(dir, entry.name), filename);
        if (found) return found;
      }
    }
  } catch {}
  return null;
}

/** Count NEEDS CLARIFICATION markers in a file */
export function countMarkers(filePath: string): number {
  try {
    return (readFileSync(filePath, "utf-8").match(/NEEDS CLARIFICATION/g) ?? []).length;
  } catch {
    return 0;
  }
}

/** Determine next phase + artifact after a phase completes */
export function resolveTransition(
  completedPhase: Phase,
  state: TaskGraph,
): { nextPhase: Phase; artifact: string; skipClarify?: boolean } | null {
  return match(completedPhase)
    .with("brainstorm", () => {
      const file = findFile(".claude/specs", "brainstorm.md");
      if (!file) return null;
      return { nextPhase: "specify" as Phase, artifact: file };
    })
    .with("specify", () => {
      const spec = state.spec_file;
      if (!spec || !existsSync(spec) || !spec.includes(".claude/specs/")) return null;
      const markers = countMarkers(spec);
      if (markers > CLARIFY_THRESHOLD) {
        return { nextPhase: "clarify" as Phase, artifact: spec };
      }
      return { nextPhase: "architecture" as Phase, artifact: spec, skipClarify: true };
    })
    .with("clarify", () => {
      const spec = state.spec_file;
      if (!spec || !existsSync(spec)) return null;
      const markers = countMarkers(spec);
      if (markers > CLARIFY_THRESHOLD) return null; // Not resolved yet
      return { nextPhase: "architecture" as Phase, artifact: spec };
    })
    .with("architecture", () => {
      const plan = state.plan_file;
      if (!plan || !existsSync(plan) || !plan.includes(".claude/plans/")) return null;
      return { nextPhase: "decompose" as Phase, artifact: plan };
    })
    .with("decompose", () => {
      return { nextPhase: "execute" as Phase, artifact: "task_graph" };
    })
    .otherwise(() => null);
}

const handler: HookHandler = async (stdin) => {
  const input: SubagentStopInput = JSON.parse(stdin);
  const completedPhase = PHASE_AGENT_MAP[input.agent_type ?? ""];
  if (!completedPhase) return { kind: "passthrough" };

  const mgr = StateManager.fromSession(input.session_id);
  if (!mgr) return { kind: "passthrough" };

  // Extract artifacts from transcript before checking transition
  if (input.agent_transcript_path && existsSync(input.agent_transcript_path)) {
    const transcriptContent = readFileSync(input.agent_transcript_path, "utf-8");
    const artifacts = parsePhaseArtifacts(transcriptContent);

    await mgr.update((s) => {
      const updates: Partial<TaskGraph> = {};

      if (artifacts.spec_file && existsSync(artifacts.spec_file)
          && artifacts.spec_file.includes(".claude/specs/") && !s.spec_file) {
        updates.spec_file = artifacts.spec_file;
      }
      if (artifacts.plan_file && existsSync(artifacts.plan_file)
          && artifacts.plan_file.includes(".claude/plans/") && !s.plan_file) {
        updates.plan_file = artifacts.plan_file;
      }

      return Object.keys(updates).length > 0 ? { ...s, ...updates } : s;
    });
  }

  // Reload after potential artifact writes
  const state = mgr.load();
  const transition = resolveTransition(completedPhase, state);
  if (!transition) return { kind: "passthrough" };

  const { nextPhase, artifact, skipClarify } = transition;

  await mgr.update((s) => ({
    ...s,
    current_phase: nextPhase,
    phase_artifacts: { ...s.phase_artifacts, [completedPhase]: artifact },
    skipped_phases: skipClarify
      ? [...new Set([...s.skipped_phases, "clarify"])]
      : s.skipped_phases,
    updated_at: new Date().toISOString(),
  }));

  process.stderr.write(`Phase advanced: ${completedPhase} → ${nextPhase}\n`);
  if (skipClarify) {
    process.stderr.write(`  (clarify auto-skipped: markers ≤ ${CLARIFY_THRESHOLD})\n`);
  }

  return { kind: "passthrough" };
};

export default handler;
