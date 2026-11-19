// Reading Claude Code's session store for cortex's recorded calls.
//
// Cortex runs `claude -p` in the project's working directory, so its calls land
// in every project's session directory, not only reclaw's. Subagent sidechains
// (`<session>/subagents/`) are never cortex calls and are not read.

import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { type RecordedCall, SessionId, assertNever } from '../domain/model.ts';
import { PROMPT_OPENINGS, parseRecordedCall } from '../domain/recorded-call.ts';

/**
 * CLI arms run from `<data>/cli-sessions`, so `claude -p` records the
 * benchmark's own calls under a project directory with this marker. They are
 * benchmark output, never corpus.
 */
export const BENCHMARK_SESSIONS_MARKER = 'bench-cortex-pipeline-cli-sessions';

export type ScanTally = Readonly<{ files: number; calls: number; notCortex: number; noAnswer: number; badTimestamp: number }>;

/** Cheap pre-filter before JSON parsing: the file mentions a job's opening line somewhere. */
const mayHoldCortexCall = (content: string): boolean => PROMPT_OPENINGS.some(([, opening]) => content.includes(opening));

export const scanRecordedCalls = async (
  projectsDir: string,
): Promise<Readonly<{ calls: readonly RecordedCall[]; tally: ScanTally }>> => {
  const calls: RecordedCall[] = [];
  let files = 0;
  let notCortex = 0;
  let noAnswer = 0;
  let badTimestamp = 0;
  for (const project of await readdir(projectsDir, { withFileTypes: true })) {
    if (!project.isDirectory() || project.name.includes(BENCHMARK_SESSIONS_MARKER)) continue;
    const dir = join(projectsDir, project.name);
    for (const name of await readdir(dir)) {
      if (!name.endsWith('.jsonl')) continue;
      files += 1;
      const content = await Bun.file(join(dir, name)).text();
      if (!mayHoldCortexCall(content)) {
        notCortex += 1;
        continue;
      }
      const parsed = parseRecordedCall(SessionId(name.slice(0, -'.jsonl'.length)), content);
      if (parsed.ok) {
        calls.push(parsed.value);
        continue;
      }
      const failure = parsed.error;
      switch (failure.kind) {
        case 'not-a-cortex-call':
          notCortex += 1;
          break;
        case 'no-answer':
          noAnswer += 1;
          break;
        case 'bad-timestamp':
          badTimestamp += 1;
          break;
        default:
          assertNever(failure);
      }
    }
  }
  return { calls, tally: { files, calls: calls.length, notCortex, noAnswer, badTimestamp } };
};
