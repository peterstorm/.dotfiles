// Prune: decide which memories of one batch to archive.
//
// A recorded prompt is parsed back into its memory rows so the arm is asked with
// the prompt cortex builds today. The model's answer becomes a decision the way
// production makes it: an answer naming an id that is not in the batch rejects
// the whole batch, and the code-enforced guards (pinned, high-confidence
// architecture/decision, too young) keep a memory however the model voted.

import { type Result, err, ok } from './model.ts';

/** One line of a prune prompt: `id | type | conf=0.85 | acc=3 | PIN | 2026-10-01 | summary`. */
export type PruneRow = Readonly<{
  id: string;
  memory_type: string;
  confidence: number;
  access_count: number;
  pinned: boolean;
  /** `YYYY-MM-DD`: the prompt carries the creation day only. */
  created_day: string;
  summary: string;
}>;

export type PrunePromptError = Readonly<{ kind: 'malformed-prune-prompt'; detail: string }>;

const MEMORIES_HEADER = '\nMEMORIES:\n';
const ROW = /^(\S+) \| (\S+) \| conf=(\d+\.\d{2}) \| acc=(\d+)( \| PIN)? \| (\d{4}-\d{2}-\d{2}) \| ([\s\S]*)$/;

/**
 * The rows a prune prompt listed, in order. A summary may hold a newline (cortex
 * slices it to 140 characters, not to one line), so a line that does not open a
 * row continues the previous row's summary.
 */
export const parsePrunePrompt = (prompt: string): Result<readonly PruneRow[], PrunePromptError> => {
  const at = prompt.lastIndexOf(MEMORIES_HEADER);
  if (at < 0) return err({ kind: 'malformed-prune-prompt', detail: 'no MEMORIES section' });
  const rows: PruneRow[] = [];
  for (const line of prompt.slice(at + MEMORIES_HEADER.length).split('\n')) {
    const m = ROW.exec(line);
    if (m === null) {
      const previous = rows.pop();
      if (previous === undefined) return err({ kind: 'malformed-prune-prompt', detail: 'first line is not a row' });
      rows.push({ ...previous, summary: `${previous.summary}\n${line}` });
      continue;
    }
    const [, id, type, conf, acc, pin, day, summary] = m;
    rows.push({
      id: id ?? '',
      memory_type: type ?? '',
      confidence: Number(conf),
      access_count: Number(acc),
      pinned: pin !== undefined,
      created_day: day ?? '',
      summary: summary ?? '',
    });
  }
  if (rows.length === 0) return err({ kind: 'malformed-prune-prompt', detail: 'no rows' });
  return ok(rows);
};

/** The answer format cortex's prune prompt asked for before the `{"candidates": …}` envelope. */
const LEGACY_FORMAT = 'Format: [{"id": "full-uuid", "reason": "short reason"}]';

/**
 * A recorded answer, in the shape today's parser reads. A reference given under
 * the legacy prompt answered as asked, with a bare array; it is wrapped in the
 * envelope so its decision is graded, not its obedience to a format it was
 * never shown. Answers to the current prompt pass through unchanged.
 */
export const asCurrentPruneAnswer = (prompt: string, answer: string): string => {
  if (!prompt.includes(LEGACY_FORMAT)) return answer;
  const start = answer.indexOf('[');
  const end = answer.lastIndexOf(']');
  return start < 0 || end < start ? answer : `{"candidates": ${answer.slice(start, end + 1)}}`;
};

/** Why cortex keeps a memory the model named; mirrors cortex's ArchiveGuard. */
export type ArchiveGuard = 'pinned' | 'stable' | 'too-young';

/**
 * Cortex's guard, passed in so the core stays free of cortex imports. Rows carry
 * only the creation day; the caller decides which instant of that day it means.
 */
export type GuardOf = (row: PruneRow, now: Date) => ArchiveGuard | null;

/** What a model's answer did to one batch. */
export type PruneDecision =
  | Readonly<{ kind: 'decided'; archived: ReadonlySet<string>; nominatedGuarded: number }>
  /** Production rejects the whole batch when the answer names an id not in it. */
  | Readonly<{ kind: 'rejected'; unknownIds: readonly string[] }>;

export const decide = (
  rows: readonly PruneRow[],
  nominated: readonly string[],
  guardOf: GuardOf,
  now: Date,
): PruneDecision => {
  const byId = new Map(rows.map((r) => [r.id, r]));
  const unknownIds = nominated.filter((id) => !byId.has(id));
  if (unknownIds.length > 0) return { kind: 'rejected', unknownIds };
  const archived = new Set<string>();
  let nominatedGuarded = 0;
  for (const id of new Set(nominated)) {
    const row = byId.get(id);
    if (row === undefined) continue;
    if (guardOf(row, now) === null) archived.add(id);
    else nominatedGuarded += 1;
  }
  return { kind: 'decided', archived, nominatedGuarded };
};

/** Per-memory archive/keep agreement for one batch both sides decided. */
export type PruneAgreement = Readonly<{
  memories: number;
  bothArchive: number;
  referenceArchive: number;
  armArchive: number;
  /** archive/keep pairs, for kappa. */
  votes: readonly (readonly ['archive' | 'keep', 'archive' | 'keep'])[];
}>;

export const pruneAgreement = (
  rows: readonly PruneRow[],
  reference: ReadonlySet<string>,
  arm: ReadonlySet<string>,
): PruneAgreement => {
  const votes = rows.map(
    (r) => [reference.has(r.id) ? 'archive' : 'keep', arm.has(r.id) ? 'archive' : 'keep'] as const,
  );
  return {
    memories: rows.length,
    bothArchive: votes.filter(([x, y]) => x === 'archive' && y === 'archive').length,
    referenceArchive: reference.size,
    armArchive: arm.size,
    votes,
  };
};
