import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { type ExtractedMemory, jaccard, matchExtractions, tokens } from './extract.ts';

const memoryArb: fc.Arbitrary<ExtractedMemory> = fc.record({
  summary: fc.lorem({ maxCount: 12 }),
  content: fc.lorem({ maxCount: 30 }),
  memory_type: fc.constantFrom('decision', 'gotcha', 'context'),
  scope: fc.constant('project'),
});

const extractionArb = fc.array(memoryArb, { maxLength: 8 }).map((memories) => ({ memories, entities: 0 }));

describe('jaccard', () => {
  test('is symmetric and within [0, 1]', () => {
    fc.assert(
      fc.property(fc.lorem(), fc.lorem(), (a, b) => {
        const x = jaccard(tokens(a), tokens(b));
        expect(x).toBe(jaccard(tokens(b), tokens(a)));
        expect(x).toBeGreaterThanOrEqual(0);
        expect(x).toBeLessThanOrEqual(1);
      }),
    );
  });

  test('ignores case, punctuation and stopwords', () => {
    expect(jaccard(tokens('The Garmin sync FAILED.'), tokens('garmin sync failed'))).toBe(1);
  });
});

describe('matchExtractions', () => {
  test('matches one-to-one: never more matches than either side has', () => {
    fc.assert(
      fc.property(extractionArb, extractionArb, (r, a) => {
        const m = matchExtractions(r, a);
        expect(m.matched).toBeLessThanOrEqual(Math.min(m.referenceCount, m.armCount));
        expect(m.unmatchedReference.length).toBe(m.referenceCount - m.matched);
        expect(m.unmatchedArm.length).toBe(m.armCount - m.matched);
        expect(m.sameType).toBeLessThanOrEqual(m.matched);
      }),
    );
  });

  test('matches an extraction against itself completely', () => {
    fc.assert(
      fc.property(extractionArb, (e) => {
        fc.pre(e.memories.every((m) => tokens(`${m.summary} ${m.content}`).size > 0));
        const m = matchExtractions(e, e);
        expect(m.matched).toBe(e.memories.length);
      }),
    );
  });
});
