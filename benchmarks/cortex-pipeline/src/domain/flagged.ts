// The review file: what an arm disagreed with the reference about, laid out for
// hand adjudication. Agreement with the reference is not accuracy; reading
// these is how "worse" is told apart from "different".

import type { CaseGrade } from './grade.ts';
import type { CaseInput } from './case-input.ts';
import type { ExtractedMemory } from './extract.ts';
import type { SessionId } from './model.ts';
import { type MemoryPair, type PairLabel, sameCategory } from './relate.ts';

export type RelateDisagreement = Readonly<{ session: SessionId; pair: MemoryPair; reference: PairLabel; arm: PairLabel }>;
export type ExtractMisses = Readonly<{
  session: SessionId;
  unmatchedReference: readonly ExtractedMemory[];
  unmatchedArm: readonly ExtractedMemory[];
}>;

export type ArmFlags = Readonly<{ arm: string; relate: readonly RelateDisagreement[]; extract: readonly ExtractMisses[] }>;

/** The disagreements in one graded case; nothing for failed answers or other jobs. */
export const flagsOf = (input: CaseInput, grade: CaseGrade): Readonly<{ relate: readonly RelateDisagreement[]; extract: readonly ExtractMisses[] }> => {
  if (grade.graded.kind !== 'usable') return { relate: [], extract: [] };
  if (input.job === 'relate' && grade.job === 'relate') {
    return {
      relate: grade.graded.value.flatMap((lp, i) => {
        const pair = input.pairs[i];
        return pair === undefined || sameCategory(lp)
          ? []
          : [{ session: grade.session, pair, reference: lp.reference, arm: lp.arm }];
      }),
      extract: [],
    };
  }
  if (grade.job === 'extract') {
    const m = grade.graded.value;
    return m.unmatchedReference.length + m.unmatchedArm.length === 0
      ? { relate: [], extract: [] }
      : { relate: [], extract: [{ session: grade.session, unmatchedReference: m.unmatchedReference, unmatchedArm: m.unmatchedArm }] };
  }
  return { relate: [], extract: [] };
};

const label = (l: PairLabel): string => (l.kind === 'none' ? 'no edge' : `${l.relation} ${l.strength.toFixed(2)}`);
const oneLine = (s: string): string => s.replace(/\s+/g, ' ').trim();

const relateBlock = (d: RelateDisagreement): string =>
  [
    `- **${d.session.slice(0, 8)}** reference: ${label(d.reference)} · arm: ${label(d.arm)}`,
    `  - source (${d.pair.source.memory_type}): ${oneLine(d.pair.source.summary)}`,
    `  - target (${d.pair.target.memory_type}): ${oneLine(d.pair.target.summary)}`,
  ].join('\n');

const extractBlock = (m: ExtractMisses): string =>
  [
    `- **${m.session.slice(0, 8)}**`,
    ...m.unmatchedReference.map((x) => `  - only reference (${x.memory_type}): ${oneLine(x.summary)}`),
    ...m.unmatchedArm.map((x) => `  - only arm (${x.memory_type}): ${oneLine(x.summary)}`),
  ].join('\n');

export const renderFlagged = (protocolId: string, arms: readonly ArmFlags[]): string =>
  [
    `# Disagreements to adjudicate — ${protocolId}`,
    '',
    'For each item decide: is the arm wrong, the reference wrong, or both defensible? Tallying those turns agreement into accuracy.',
    ...arms.flatMap((a) => [
      '',
      `## ${a.arm}`,
      '',
      `### Relate (${a.relate.length} pairs)`,
      '',
      ...(a.relate.length === 0 ? ['_None._'] : a.relate.map(relateBlock)),
      '',
      `### Extract (${a.extract.length} cases with unmatched memories)`,
      '',
      ...(a.extract.length === 0 ? ['_None._'] : a.extract.map(extractBlock)),
    ]),
    '',
  ].join('\n');
