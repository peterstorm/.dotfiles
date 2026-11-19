// Which skill a scheduled prompt came from.
//
// Reclaw does not stamp the skill id into the prompt, and the templates were
// edited during the period under review. So a prompt is matched against every
// committed revision of every skill: a *signature line* is a literal template
// line that appears in exactly one skill's history. A rendered prompt contains
// its template's literal lines verbatim, so counting signature hits identifies
// the skill, and the revision with the most matching lines is the one that ran.

import type { SkillId } from './model.ts';

export type SkillRevision = Readonly<{
  skill: SkillId;
  commit: string;
  committedAt: Date;
  promptTemplate: string;
  /** The skill's `timeout:` in seconds at this revision, when set. */
  timeoutSec: number | null;
}>;

export type SkillCatalog = Readonly<{
  /** Every revision with its literal lines, computed once. */
  revisions: readonly Readonly<{ revision: SkillRevision; lines: ReadonlySet<string> }>[];
  signatures: ReadonlyMap<SkillId, ReadonlySet<string>>;
}>;

export type Classification =
  | Readonly<{ kind: 'skill'; skill: SkillId; revision: SkillRevision; hits: number }>
  | Readonly<{ kind: 'ambiguous'; candidates: readonly SkillId[] }>
  | Readonly<{ kind: 'unclassified' }>;

/** A line short enough to be shared boilerplate ("## Output") never identifies a skill. */
const MIN_SIGNATURE_LENGTH = 25;
/** Signature hits a prompt needs before it is attributed at all. */
export const MIN_HITS = 3;

const normalise = (line: string): string => line.trim().replace(/\s+/g, ' ');

/** The literal (variable-free) lines of a template, normalised. */
const literalLines = (template: string): ReadonlySet<string> =>
  new Set(
    template
      .split('\n')
      .map(normalise)
      .filter((l) => l.length >= MIN_SIGNATURE_LENGTH && !l.includes('{{')),
  );

const promptLines = (prompt: string): ReadonlySet<string> =>
  new Set(prompt.split('\n').map(normalise).filter((l) => l.length > 0));

export const buildCatalog = (revisions: readonly SkillRevision[]): SkillCatalog => {
  const withLines = revisions.map((revision) => ({ revision, lines: literalLines(revision.promptTemplate) }));
  const owners = new Map<string, Set<SkillId>>();
  for (const { revision, lines } of withLines) {
    for (const line of lines) {
      const set = owners.get(line) ?? new Set<SkillId>();
      set.add(revision.skill);
      owners.set(line, set);
    }
  }
  const signatures = new Map<SkillId, Set<string>>();
  for (const [line, skills] of owners) {
    if (skills.size !== 1) continue;
    const [skill] = [...skills];
    if (skill === undefined) continue;
    const set = signatures.get(skill) ?? new Set<string>();
    set.add(line);
    signatures.set(skill, set);
  }
  return { revisions: withLines, signatures };
};

const countHits = (lines: ReadonlySet<string>, within: ReadonlySet<string>): number => {
  let n = 0;
  for (const l of lines) if (within.has(l)) n += 1;
  return n;
};

/**
 * The revision that ran: most literal lines present in the prompt; ties go to
 * the newest revision committed before the run, else the oldest overall.
 */
const bestRevision = (
  catalog: SkillCatalog,
  skill: SkillId,
  lines: ReadonlySet<string>,
  at: Date,
): SkillRevision | undefined => {
  const scored = catalog.revisions
    .filter((e) => e.revision.skill === skill)
    .map((e) => ({ r: e.revision, score: countHits(e.lines, lines) }));
  const top = Math.max(...scored.map((s) => s.score));
  const tied = scored.filter((s) => s.score === top).map((s) => s.r);
  const before = tied.filter((r) => r.committedAt <= at).sort((a, b) => +b.committedAt - +a.committedAt);
  return before[0] ?? [...tied].sort((a, b) => +a.committedAt - +b.committedAt)[0];
};

export const classify = (catalog: SkillCatalog, prompt: string, at: Date): Classification => {
  const lines = promptLines(prompt);
  const ranked = [...catalog.signatures]
    .map(([skill, sigs]) => ({ skill, hits: countHits(sigs, lines) }))
    .filter((s) => s.hits > 0)
    .sort((a, b) => b.hits - a.hits);
  const [first, second] = ranked;
  if (first === undefined || first.hits < MIN_HITS) return { kind: 'unclassified' };
  // A clear winner has at least twice the runner-up's evidence.
  if (second !== undefined && second.hits * 2 > first.hits) {
    return { kind: 'ambiguous', candidates: ranked.filter((s) => s.hits * 2 > first.hits).map((s) => s.skill) };
  }
  const revision = bestRevision(catalog, first.skill, lines, at);
  if (revision === undefined) return { kind: 'unclassified' };
  return { kind: 'skill', skill: first.skill, revision, hits: first.hits };
};
