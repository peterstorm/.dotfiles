// Relate: classify the relationship of each memory pair in a batch.
//
// Recorded prompts are parsed back into their pairs so the arm is asked with the
// prompt cortex builds TODAY (the template gained `pair_index` after most of the
// corpus was recorded). The answer for a batch is one label per pair: `none`
// when the model returned no edge for it (cortex keeps only strength >= 0.3),
// else the relation and its strength.

import {
  type EdgeRelation,
  EDGE_RELATIONS,
  type MemoryType,
  type Result,
  assertNever,
  err,
  isMemoryType,
  ok,
} from './model.ts';
import { cohenKappa } from './stats.ts';

export type PairMemory = Readonly<{ id: string; memory_type: MemoryType; summary: string; content: string }>;
export type MemoryPair = Readonly<{ source: PairMemory; target: PairMemory }>;

export type PairLabel =
  | Readonly<{ kind: 'none' }>
  | Readonly<{ kind: 'edge'; relation: EdgeRelation; strength: number }>;

export type RelatePromptError = Readonly<{ kind: 'malformed-relate-prompt'; detail: string }>;

const SECTION_START = 'Memory Pairs:\n';
const SECTION_END = '\n\nEdge Relation Types:';

const PAIR_BODY =
  /^\nPair (\d+):\n(?: {2}pair_index: \d+\n)? {2}Source \[([^\]\n]+)\]:\n {4}Type: ([^\n]*)\n {4}Summary: ([\s\S]*?)\n {4}Content: ([\s\S]*?)\n\n {2}Target \[([^\]\n]+)\]:\n {4}Type: ([^\n]*)\n {4}Summary: ([\s\S]*?)\n {4}Content: ([\s\S]*)$/;

const memory = (id: string, type: string, summary: string, content: string): Result<PairMemory, RelatePromptError> =>
  isMemoryType(type)
    ? ok({ id, memory_type: type, summary, content })
    : err({ kind: 'malformed-relate-prompt', detail: `unknown memory type '${type}'` });

/**
 * The pairs a relate prompt asked about, in order. Accepts the template with and
 * without the `pair_index:` line. Each pair description ends in a newline and
 * descriptions are joined by one more, so pair k's chunk runs up to the
 * `\nPair k+1:\n` that starts the next one and ends with `\n\n` (one `\n` for
 * the last pair).
 */
export const parseRelatePrompt = (prompt: string): Result<readonly MemoryPair[], RelatePromptError> => {
  const start = prompt.indexOf(SECTION_START);
  const end = prompt.lastIndexOf(SECTION_END);
  if (start < 0 || end < start) return err({ kind: 'malformed-relate-prompt', detail: 'no Memory Pairs section' });
  const section = prompt.slice(start + SECTION_START.length, end);

  const starts: number[] = [];
  for (let k = 1, from = 0; ; k++) {
    const at = section.indexOf(`\nPair ${k}:\n`, from);
    if (at < 0) break;
    starts.push(at);
    from = at + 1;
  }
  if (starts.length === 0 || starts[0] !== 0) {
    return err({ kind: 'malformed-relate-prompt', detail: 'section does not open with Pair 1' });
  }

  const pairs: MemoryPair[] = [];
  for (let i = 0; i < starts.length; i++) {
    const isLast = i === starts.length - 1;
    const chunk = section.slice(starts[i], isLast ? section.length : starts[i + 1]);
    const trailer = isLast ? '\n' : '\n\n';
    if (!chunk.endsWith(trailer)) {
      return err({ kind: 'malformed-relate-prompt', detail: `pair ${i + 1} does not end with its separator` });
    }
    const m = PAIR_BODY.exec(chunk.slice(0, -trailer.length));
    if (m === null) return err({ kind: 'malformed-relate-prompt', detail: `pair ${i + 1} does not match the template` });
    const [, , sId, sType, sSummary, sContent, tId, tType, tSummary, tContent] = m;
    const source = memory(sId ?? '', sType ?? '', sSummary ?? '', sContent ?? '');
    if (!source.ok) return source;
    const target = memory(tId ?? '', tType ?? '', tSummary ?? '', tContent ?? '');
    if (!target.ok) return target;
    pairs.push({ source: source.value, target: target.value });
  }
  return ok(pairs);
};

// ─── Agreement ───────────────────────────────────────────────────────────────

/** Cortex's own strength bands from the prompt; below 0.3 is no edge at all. */
export type StrengthBand = 'weak' | 'moderate' | 'strong';

export const strengthBand = (strength: number): StrengthBand =>
  strength >= 0.8 ? 'strong' : strength >= 0.5 ? 'moderate' : 'weak';

/** The category a label falls in for agreement statistics: `none` or the relation. */
export type RelateCategory = 'none' | EdgeRelation;
export const RELATE_CATEGORIES: readonly RelateCategory[] = ['none', ...EDGE_RELATIONS];

export const categoryOf = (label: PairLabel): RelateCategory => {
  switch (label.kind) {
    case 'none':
      return 'none';
    case 'edge':
      return label.relation;
    default:
      return assertNever(label);
  }
};

/** One pair answered by both the reference and the arm. */
export type LabelPair = Readonly<{ reference: PairLabel; arm: PairLabel }>;

/** Pairs of labels, position by position. Callers guarantee both answers cover the same batch. */
export const zipLabels = (reference: readonly PairLabel[], arm: readonly PairLabel[]): readonly LabelPair[] =>
  reference.flatMap((r, i) => {
    const a = arm[i];
    return a === undefined ? [] : [{ reference: r, arm: a }];
  });

/** Whether the reference and the arm put the pair in the same category. */
export const sameCategory = (p: LabelPair): boolean => categoryOf(p.reference) === categoryOf(p.arm);

/** Cohen's κ over the 8 categories (no edge + 7 relations). */
export const categoryKappa = (pairs: readonly LabelPair[]): number | null =>
  cohenKappa(pairs.map((p) => [categoryOf(p.reference), categoryOf(p.arm)] as const));

/** Cohen's κ over edge / no edge. */
export const edgeKappa = (pairs: readonly LabelPair[]): number | null =>
  cohenKappa(pairs.map((p) => [p.reference.kind, p.arm.kind] as const));

export type EdgeAgreement = Readonly<{
  /** Pairs where both answered with an edge. */
  bothEdge: number;
  sameRelation: number;
  /** Among both-edge pairs with the same relation, how many fall in the same strength band. */
  sameBand: number;
}>;

export const edgeAgreement = (pairs: readonly LabelPair[]): EdgeAgreement =>
  pairs.reduce<EdgeAgreement>(
    (acc, { reference, arm }) => {
      if (reference.kind !== 'edge' || arm.kind !== 'edge') return acc;
      const same = reference.relation === arm.relation;
      return {
        bothEdge: acc.bothEdge + 1,
        sameRelation: acc.sameRelation + (same ? 1 : 0),
        sameBand: acc.sameBand + (same && strengthBand(reference.strength) === strengthBand(arm.strength) ? 1 : 0),
      };
    },
    { bothEdge: 0, sameRelation: 0, sameBand: 0 },
  );
