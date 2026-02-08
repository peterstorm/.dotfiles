/**
 * Complete wave gate after reviews pass.
 * Verifies: test evidence, new tests, reviews, spec alignment, no critical findings.
 * Then marks wave tasks completed, updates GitHub issue checkboxes, advances wave.
 *
 * Usage: bun cli.ts helper complete-wave-gate [--wave N]
 */

import { execSync } from "node:child_process";
import type { HookHandler, TaskGraph, Task, WaveGate } from "../../types";
import { TASK_GRAPH_PATH } from "../../config";
import { StateManager } from "../../state-manager";

function parseWaveArg(args: string[]): number | null {
  const idx = args.indexOf("--wave");
  if (idx >= 0 && args[idx + 1]) return Number(args[idx + 1]);
  return null;
}

interface GateCheck {
  passed: boolean;
  message: string;
}

/** Check 1: All tasks have test evidence */
export function checkTestEvidence(tasks: Task[]): GateCheck {
  const missing = tasks.filter((t) => !t.tests_passed);
  if (missing.length > 0) {
    return {
      passed: false,
      message: `FAILED: Not all tasks have test evidence.\n  Missing: ${missing.map((t) => t.id).join(", ")}`,
    };
  }
  const lines = tasks.map((t) => `     ${t.id}: ${t.test_evidence ?? "evidence present"}`);
  return { passed: true, message: `1. Test evidence verified (${tasks.length}/${tasks.length} tasks):\n${lines.join("\n")}` };
}

/** Check 1b: New tests written or not required */
export function checkNewTests(tasks: Task[]): GateCheck {
  const missing = tasks.filter((t) => t.new_tests_required !== false && !t.new_tests_written);
  if (missing.length > 0) {
    return {
      passed: false,
      message: `FAILED: Not all tasks satisfied new-test requirement.\n  Missing: ${missing.map((t) => t.id).join(", ")}`,
    };
  }
  const lines = tasks.map((t) => {
    const evidence = t.new_test_evidence ?? (t.new_tests_required === false ? "not required" : "new tests present");
    return `     ${t.id}: ${evidence}`;
  });
  return { passed: true, message: `   New tests verified (${tasks.length}/${tasks.length} tasks):\n${lines.join("\n")}` };
}

/** Check 2: All tasks reviewed */
export function checkReviews(tasks: Task[]): GateCheck {
  const reviewed = tasks.filter((t) => t.review_status === "passed" || t.review_status === "blocked");
  if (reviewed.length !== tasks.length) {
    const unreviewed = tasks.filter((t) => !t.review_status || t.review_status === "pending").map((t) => t.id);
    const failed = tasks.filter((t) => t.review_status === "evidence_capture_failed").map((t) => t.id);
    const parts = ["FAILED: Not all tasks have been reviewed."];
    if (failed.length > 0) parts.push(`  Evidence capture failed: ${failed.join(", ")}`);
    if (unreviewed.length > 0) parts.push(`  Unreviewed: ${unreviewed.join(", ")}`);
    return { passed: false, message: parts.join("\n") };
  }
  const lines = tasks.map((t) => `     ${t.id}: ${t.review_status}`);
  return { passed: true, message: `2. Reviews verified (${tasks.length}/${tasks.length} tasks):\n${lines.join("\n")}` };
}

/** Check 3: Spec alignment */
function checkSpecAlignment(state: TaskGraph, wave: number): GateCheck {
  if (!state.spec_check) {
    return { passed: true, message: "3. Spec alignment: skipped (no spec-check data)." };
  }
  if (state.spec_check.wave !== wave) {
    return { passed: true, message: `3. Spec alignment: WARNING — was run for wave ${state.spec_check.wave}, not ${wave}.` };
  }
  if ((state.spec_check.critical_count ?? 0) > 0) {
    const findings = (state.spec_check.critical_findings ?? []).map((f) => `  - ${f}`).join("\n");
    return {
      passed: false,
      message: `FAILED: Spec alignment has ${state.spec_check.critical_count} critical findings.\n${findings}`,
    };
  }
  return { passed: true, message: `3. Spec alignment verified (verdict: ${state.spec_check.verdict}).` };
}

/** Check 4: No critical code review findings */
export function checkCriticalFindings(tasks: Task[]): GateCheck {
  const totalCritical = tasks.reduce((sum, t) => sum + (t.critical_findings?.length ?? 0), 0);
  if (totalCritical > 0) {
    const details = tasks
      .filter((t) => (t.critical_findings?.length ?? 0) > 0)
      .map((t) => `  ${t.id}: ${t.critical_findings!.join(", ")}`)
      .join("\n");
    return { passed: false, message: `FAILED: ${totalCritical} critical code review findings.\n${details}` };
  }
  return { passed: true, message: "4. No critical code review findings." };
}

/** Update GitHub issue checkboxes */
function updateGitHubIssue(state: TaskGraph, taskIds: string[]): void {
  const issue = state.github_issue;
  if (!issue) return;

  try {
    const repoFlag = state.github_repo ? `--repo ${state.github_repo}` : "";
    const body = execSync(`gh issue view ${issue} ${repoFlag} --json body -q '.body'`, { encoding: "utf-8" });

    let updated = body;
    for (const id of taskIds) {
      updated = updated.replace(new RegExp(`- \\[ \\] ${id}:`, "g"), `- [x] ${id}:`);
    }

    execSync(`gh issue edit ${issue} ${repoFlag} --body ${JSON.stringify(updated)}`, { stdio: "pipe" });
    process.stderr.write(`Updated checkboxes in issue #${issue}\n`);
  } catch {}
}

const handler: HookHandler = async (_stdin, args) => {
  const mgr = StateManager.fromPath(TASK_GRAPH_PATH);
  if (!mgr) return { kind: "error", message: `No task graph at ${TASK_GRAPH_PATH}` };

  const state = mgr.load();
  const wave = parseWaveArg(args) ?? state.current_wave ?? 1;
  const waveTasks = state.tasks.filter((t) => t.wave === wave);

  process.stderr.write(`Completing wave ${wave} gate...\n\n`);

  // Run all checks
  const checks = [
    checkTestEvidence(waveTasks),
    checkNewTests(waveTasks),
    checkReviews(waveTasks),
    checkSpecAlignment(state, wave),
    checkCriticalFindings(waveTasks),
  ];

  for (const check of checks) {
    process.stderr.write(check.message + "\n");
    if (!check.passed) {
      return { kind: "error", message: check.message };
    }
  }

  // Mark test evidence verified on wave gate
  await mgr.update((s) => ({
    ...s,
    wave_gates: {
      ...s.wave_gates,
      [String(wave)]: {
        ...(s.wave_gates[String(wave)] ?? { impl_complete: false, tests_passed: null, reviews_complete: false, blocked: false }),
        tests_passed: true,
      },
    },
  }));

  // All passed — advance
  process.stderr.write("\nAll checks passed. Advancing...\n");

  const taskIds = waveTasks.map((t) => t.id);

  // Mark tasks completed + gate passed
  await mgr.update((s) => ({
    ...s,
    tasks: s.tasks.map((t) =>
      t.wave === wave
        ? { ...t, status: "completed" as const, review_status: "passed" as const }
        : t
    ),
    wave_gates: {
      ...s.wave_gates,
      [String(wave)]: {
        ...(s.wave_gates[String(wave)] ?? { impl_complete: false, tests_passed: null, reviews_complete: false, blocked: false }),
        reviews_complete: true,
        blocked: false,
      },
    },
  }));

  // Update GitHub issue
  updateGitHubIssue(state, taskIds);

  // Advance wave
  const maxWave = Math.max(...state.tasks.map((t) => t.wave));
  const nextWave = wave + 1;

  if (nextWave <= maxWave) {
    await mgr.update((s) => ({
      ...s,
      current_wave: nextWave,
      wave_gates: {
        ...s.wave_gates,
        [String(nextWave)]: { impl_complete: false, tests_passed: null, reviews_complete: false, blocked: false },
      },
    }));
    process.stderr.write(`Advanced to wave ${nextWave}.\n`);
  } else {
    process.stderr.write("\n=== All waves complete! ===\nRun /loom --complete to finalize.\n");
  }

  return { kind: "passthrough" };
};

export default handler;
