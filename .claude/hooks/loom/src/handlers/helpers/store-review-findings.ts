/**
 * Store review findings for a task.
 * Usage: bun cli.ts helper store-review-findings --task T1
 * Reads CRITICAL:/ADVISORY: lines from stdin.
 */

import type { HookHandler, ReviewStatus } from "../../types";
import { TASK_GRAPH_PATH } from "../../config";
import { StateManager } from "../../state-manager";

const handler: HookHandler = async (stdin, args) => {
  const taskIdx = args.indexOf("--task");
  const taskId = taskIdx >= 0 ? args[taskIdx + 1] : null;
  if (!taskId) return { kind: "error", message: "--task required" };

  const mgr = StateManager.fromPath(TASK_GRAPH_PATH);
  if (!mgr) return { kind: "error", message: `No task graph at ${TASK_GRAPH_PATH}` };

  const critical: string[] = [];
  const advisory: string[] = [];

  for (const line of stdin.split("\n")) {
    const critMatch = line.match(/^CRITICAL:\s*(.*)/);
    if (critMatch) { critical.push(critMatch[1]); continue; }
    const advMatch = line.match(/^ADVISORY:\s*(.*)/);
    if (advMatch) advisory.push(advMatch[1]);
  }

  const reviewStatus: ReviewStatus = critical.length > 0 ? "blocked" : "passed";

  await mgr.update((s) => ({
    ...s,
    tasks: s.tasks.map((t) =>
      t.id === taskId
        ? { ...t, critical_findings: critical, advisory_findings: advisory, review_status: reviewStatus }
        : t
    ),
  }));

  process.stderr.write(`Stored findings for ${taskId}: ${critical.length} critical, ${advisory.length} advisory\n`);

  if (critical.length > 0) {
    const state = mgr.load();
    const task = state.tasks.find((t) => t.id === taskId);
    if (task) {
      await mgr.update((s) => ({
        ...s,
        wave_gates: {
          ...s.wave_gates,
          [String(task.wave)]: {
            ...(s.wave_gates[String(task.wave)] ?? { impl_complete: false, tests_passed: null, reviews_complete: false, blocked: false }),
            blocked: true,
          },
        },
      }));
    }
  }

  return { kind: "passthrough" };
};

export default handler;
