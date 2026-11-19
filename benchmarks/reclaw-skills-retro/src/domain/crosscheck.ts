// Validating the prompt classifier against ground truth reclaw itself recorded.
//
// The anomaly log names the skill of every suppressed or failed scheduled run.
// Joining log lines to runs by end time and comparing skills measures the
// classifier on exactly the runs where reclaw knew the answer.

import { type Run, type SkillId, assertNever } from './model.ts';
import type { Classification } from './skill-catalog.ts';

/** `at` is when reclaw finished the run; `durationMs`, when logged, places its start too. */
export type QualityLogEntry = Readonly<{ at: Date; skill: SkillId; status: string; durationMs: number | null }>;

export type CrossCheck = Readonly<{
  joined: number;
  agree: number;
  disagree: readonly Readonly<{ file: string; logged: SkillId; classified: string }>[];
}>;

/** How far a log line's timestamp may sit from the run's last session entry. */
const JOIN_TOLERANCE_MS = 120_000;

const label = (c: Classification): string => {
  switch (c.kind) {
    case 'skill':
      return c.skill;
    case 'ambiguous':
      return `ambiguous(${c.candidates.join('|')})`;
    case 'unclassified':
      return 'unclassified';
    default:
      return assertNever(c);
  }
};

export const crossCheck = (
  runs: readonly Readonly<{ run: Run; classification: Classification }>[],
  log: readonly QualityLogEntry[],
): CrossCheck => {
  const byEnd = [...runs].sort((a, b) => +a.run.endedAt - +b.run.endedAt);
  const used = new Set<string>();
  let agree = 0;
  const disagree: { file: string; logged: SkillId; classified: string }[] = [];
  for (const entry of log) {
    // Skills scheduled in the same minute (the 22:00 cortex chain) end close
    // together; the start time separates them when the log carries a duration.
    const startGap = (r: Run): number =>
      entry.durationMs === null ? 0 : Math.abs(+r.startedAt - (+entry.at - entry.durationMs));
    const nearest = byEnd
      .flatMap((r) => {
        const end = Math.abs(+r.run.endedAt - +entry.at);
        return used.has(r.run.file) || end > JOIN_TOLERANCE_MS ? [] : [{ r, gap: end + startGap(r.run) }];
      })
      .sort((a, b) => a.gap - b.gap)[0];
    if (nearest === undefined) continue;
    used.add(nearest.r.run.file);
    const c = nearest.r.classification;
    if (c.kind === 'skill' && c.skill === entry.skill) agree += 1;
    else disagree.push({ file: nearest.r.run.file, logged: entry.skill, classified: label(c) });
  }
  return { joined: agree + disagree.length, agree, disagree };
};
