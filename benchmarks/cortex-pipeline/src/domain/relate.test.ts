import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { type LabelPair, type PairLabel, edgeAgreement, parseRelatePrompt, strengthBand, zipLabels } from './relate.ts';

const TAIL = '\n\nEdge Relation Types:\n- relates_to: General semantic connection\n';

// The pre-pair_index template, as recorded in most of the corpus.
const LEGACY = `Classify relationships between memory pairs.

Memory Pairs:

Pair 1:
  Source [a1]:
    Type: architecture
    Summary: First summary.
    Content: Line one.

Line three after a blank line.

  Target [b1]:
    Type: gotcha
    Summary: Target summary.
    Content: target content


Pair 2:
  Source [a2]:
    Type: context
    Summary: s2
    Content: c2

  Target [b2]:
    Type: decision
    Summary: t2
    Content: last content
${TAIL}`;

describe('parseRelatePrompt', () => {
  test('reads the legacy template, including content with blank lines', () => {
    const parsed = parseRelatePrompt(LEGACY);
    expect(parsed).toEqual({
      ok: true,
      value: [
        {
          source: { id: 'a1', memory_type: 'architecture', summary: 'First summary.', content: 'Line one.\n\nLine three after a blank line.' },
          target: { id: 'b1', memory_type: 'gotcha', summary: 'Target summary.', content: 'target content' },
        },
        {
          source: { id: 'a2', memory_type: 'context', summary: 's2', content: 'c2' },
          target: { id: 'b2', memory_type: 'decision', summary: 't2', content: 'last content' },
        },
      ],
    });
  });

  test('reads the template with pair_index lines to the same pairs', () => {
    const indexed = LEGACY.replace('Pair 1:\n', 'Pair 1:\n  pair_index: 1\n').replace('Pair 2:\n', 'Pair 2:\n  pair_index: 2\n');
    expect(parseRelatePrompt(indexed)).toEqual(parseRelatePrompt(LEGACY));
  });

  test('rejects an unknown memory type and a prompt without the section', () => {
    expect(parseRelatePrompt(LEGACY.replace('Type: gotcha', 'Type: rumour')).ok).toBe(false);
    expect(parseRelatePrompt('Classify relationships between memory pairs.\n\nnothing here').ok).toBe(false);
  });
});

describe('strengthBand', () => {
  test("uses cortex's prompt bands at their boundaries", () => {
    expect(strengthBand(0.3)).toBe('weak');
    expect(strengthBand(0.49)).toBe('weak');
    expect(strengthBand(0.5)).toBe('moderate');
    expect(strengthBand(0.79)).toBe('moderate');
    expect(strengthBand(0.8)).toBe('strong');
    expect(strengthBand(1)).toBe('strong');
  });
});

const labelArb: fc.Arbitrary<PairLabel> = fc.oneof(
  fc.constant({ kind: 'none' } as const),
  fc.record({
    kind: fc.constant('edge' as const),
    relation: fc.constantFrom('relates_to', 'refines', 'supersedes' as const),
    strength: fc.double({ min: 0.3, max: 1, noNaN: true }),
  }),
);

describe('edgeAgreement', () => {
  test('counts nest: same band ≤ same relation ≤ both edge ≤ pairs', () => {
    fc.assert(
      fc.property(fc.array(fc.record({ reference: labelArb, arm: labelArb })), (pairs: LabelPair[]) => {
        const a = edgeAgreement(pairs);
        expect(a.sameBand).toBeLessThanOrEqual(a.sameRelation);
        expect(a.sameRelation).toBeLessThanOrEqual(a.bothEdge);
        expect(a.bothEdge).toBeLessThanOrEqual(pairs.length);
      }),
    );
  });

  test('is symmetric in reference and arm', () => {
    fc.assert(
      fc.property(fc.array(fc.record({ reference: labelArb, arm: labelArb })), (pairs: LabelPair[]) => {
        const swapped = pairs.map((p) => ({ reference: p.arm, arm: p.reference }));
        expect(edgeAgreement(swapped)).toEqual(edgeAgreement(pairs));
      }),
    );
  });
});

describe('zipLabels', () => {
  test('pairs labels by position and stops at the shorter list', () => {
    const none = { kind: 'none' } as const;
    const edge = { kind: 'edge', relation: 'refines', strength: 0.5 } as const;
    expect(zipLabels([none, edge], [edge])).toEqual([{ reference: none, arm: edge }]);
  });
});
