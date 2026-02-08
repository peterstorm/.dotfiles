/**
 * Mark task "implemented" when impl agent completes.
 *
 * 1. Extract test evidence from Bash tool output (anti-spoofing)
 * 2. Verify new tests written via git diff + assertion density
 * 3. Atomic state write with files_modified, tests_passed, new_tests_written
 * 4. Detect wave completion → signal /wave-gate
 */

import { existsSync, readFileSync } from "node:fs";
import { match, P } from "ts-pattern";
import type { HookHandler, SubagentStopInput, TaskGraph, Task } from "../../types";
import { IMPL_AGENTS, REVIEW_AGENTS } from "../../config";
import { StateManager } from "../../state-manager";
import { extractTaskId } from "../../utils/extract-task-id";
import { parseTranscript } from "../../parsers/parse-transcript";
import { parseFilesModified } from "../../parsers/parse-files-modified";
import { parseBashTestOutput } from "../../parsers/parse-bash-test-output";
import * as git from "../../utils/git";

// --- Pure: extract test pass evidence from bash output ---

interface TestEvidence {
  passed: boolean;
  evidence: string;
}

export function extractTestEvidence(bashOutput: string): TestEvidence {
  // Java/Maven
  if (/BUILD SUCCESS/.test(bashOutput)) {
    const cleaned = bashOutput.replace(/\*\*/g, "");
    const maven = cleaned.match(/Tests run: \d+, Failures: 0, Errors: 0/);
    if (maven) return { passed: true, evidence: `maven: ${maven[0]}` };
  }

  // Node/Mocha: "N passing" without "N failing"
  const passing = bashOutput.match(/(\d+) passing/);
  if (passing) {
    const failMatch = bashOutput.match(/(\d+) failing/);
    if (!failMatch || failMatch[1] === "0") {
      return { passed: true, evidence: `node: ${passing[0]}` };
    }
  }

  // Vitest: "Tests  N passed" or "Test Files  N passed"
  const vitest = bashOutput.match(/Tests?\s+\d+ passed/);
  if (vitest) {
    const vitestFailed = bashOutput.match(/Tests?\s+\d+ failed/);
    if (!vitestFailed) return { passed: true, evidence: `vitest: ${vitest[0]}` };
  }

  // pytest: "N passed" without "N failed"
  const pytest = bashOutput.match(/(\d+) passed/);
  if (pytest) {
    const pyFail = bashOutput.match(/(\d+) failed/);
    if (!pyFail || pyFail[1] === "0") {
      return { passed: true, evidence: `pytest: ${pytest[0]}` };
    }
  }

  return { passed: false, evidence: "" };
}

// --- Pure: determine new test evidence from diff ---

interface NewTestEvidence {
  written: boolean;
  evidence: string;
}

export function analyzeNewTests(
  diff: string,
  newTestsRequired: boolean | undefined,
): NewTestEvidence {
  if (newTestsRequired === false) {
    return { written: false, evidence: "new_tests_required=false (skipped)" };
  }

  const tests = git.countNewTests(diff);
  const assertions = tests.total > 0 ? git.countAssertions(diff) : 0;

  if (tests.total > 0 && assertions > 0) {
    const details = [
      tests.java > 0 ? `java: ${tests.java} @Test/@Property` : "",
      tests.ts > 0 ? `ts: ${tests.ts} it/test/describe` : "",
      tests.python > 0 ? `python: ${tests.python} test functions` : "",
    ].filter(Boolean).join("; ");
    return {
      written: true,
      evidence: `${tests.total} new test methods, ${assertions} assertions (${details})`,
    };
  }

  if (tests.total > 0 && assertions === 0) {
    return { written: false, evidence: `${tests.total} test methods but 0 assertions (empty stubs?)` };
  }

  return { written: false, evidence: "" };
}

// --- Git diff collection ---

function collectDiff(filesModified: string[], startSha: string | undefined): string {
  if (filesModified.length > 0) {
    const tracked = filesModified.filter((f) => git.isTracked(f));
    const untracked = filesModified.filter((f) => existsSync(f) && !git.isTracked(f));

    const parts = [
      git.diffFiles(tracked),
      git.diffFilesStaged(tracked),
      ...untracked.map((f) => git.diffUntracked(f)),
    ];

    const combined = parts.join("\n");
    if (combined.trim()) return combined;
  }

  // Fallback: SHA-based or branch-based diff
  if (startSha) {
    return [git.diff(startSha, "HEAD"), git.diff(), git.diffStaged()].join("\n");
  }

  const branch = git.defaultBranch();
  const base = git.mergeBase(branch);
  const committed = base ? git.diff(base, "HEAD") : git.diff("HEAD~1", "HEAD");
  return [committed, git.diff(), git.diffStaged()].join("\n");
}

const handler: HookHandler = async (stdin) => {
  const input: SubagentStopInput = JSON.parse(stdin);
  const agentType = input.agent_type ?? "";

  // Skip non-impl agents
  if (!IMPL_AGENTS.has(agentType)) return { kind: "passthrough" };

  const mgr = StateManager.fromSession(input.session_id);
  if (!mgr) return { kind: "passthrough" };

  // Parse transcript (read file content, then parse)
  const transcriptContent = input.agent_transcript_path && existsSync(input.agent_transcript_path)
    ? readFileSync(input.agent_transcript_path, "utf-8")
    : "";
  const transcript = parseTranscript(transcriptContent);
  const filesModified = parseFilesModified(transcriptContent);
  const bashTestOutput = parseBashTestOutput(transcriptContent);

  // Extract task ID
  const taskId = extractTaskId(transcript);

  // Crash detection: impl agent completed without parseable task ID
  if (!taskId) {
    const state = mgr.load();
    const executing = state.executing_tasks ?? [];
    if (executing.length > 0) {
      process.stderr.write(`CRASH DETECTED: ${agentType} completed without task ID\n`);
      await mgr.update((s) => ({
        ...s,
        tasks: s.tasks.map((t) =>
          executing.includes(t.id)
            ? { ...t, status: "failed" as const, failure_reason: "agent_crash: no task ID in output", retry_count: (t.retry_count ?? 0) + 1 }
            : t
        ),
        executing_tasks: [],
      }));
    }
    return { kind: "passthrough" };
  }

  const state = mgr.load();
  const task = state.tasks.find((t) => t.id === taskId);
  if (!task) return { kind: "passthrough" };

  // Skip if already completed, or implemented with evidence
  if (task.status === "completed") return { kind: "passthrough" };
  if (task.status === "implemented" && task.tests_passed !== undefined) {
    return { kind: "passthrough" };
  }

  // Section 1: Test evidence from bash output
  const testEvidence = extractTestEvidence(bashTestOutput);

  // Section 2: New test verification via git diff
  let newTestEvidence: NewTestEvidence = { written: false, evidence: "" };
  if (git.isGitRepo()) {
    const fullDiff = collectDiff(filesModified, task.start_sha);
    newTestEvidence = analyzeNewTests(fullDiff, task.new_tests_required);
  }

  // Section 3: Atomic state write
  await mgr.update((s) => {
    const updatedTasks = s.tasks.map((t) =>
      t.id === taskId
        ? {
            ...t,
            status: "implemented" as const,
            tests_passed: testEvidence.passed,
            test_evidence: testEvidence.evidence,
            files_modified: filesModified,
            new_tests_written: newTestEvidence.written,
            new_test_evidence: newTestEvidence.evidence,
          }
        : t
    );

    return {
      ...s,
      tasks: updatedTasks,
      executing_tasks: (s.executing_tasks ?? []).filter((id) => id !== taskId),
    };
  });

  process.stderr.write(`Task ${taskId} implemented.\n`);

  // Check wave completion
  const updated = mgr.load();
  const currentWave = updated.current_wave ?? 1;
  const waveIncomplete = updated.tasks
    .filter((t) => t.wave === currentWave)
    .some((t) => t.status !== "implemented" && t.status !== "completed");

  if (!waveIncomplete) {
    await mgr.update((s) => ({
      ...s,
      wave_gates: {
        ...s.wave_gates,
        [String(currentWave)]: {
          ...(s.wave_gates[String(currentWave)] ?? { impl_complete: false, tests_passed: null, reviews_complete: false, blocked: false }),
          impl_complete: true,
        },
      },
    }));
    process.stderr.write(`\nWave ${currentWave} implementation complete. Run: /wave-gate\n`);
  }

  return { kind: "passthrough" };
};

export default handler;
