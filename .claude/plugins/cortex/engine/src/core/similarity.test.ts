import { describe, it, expect } from 'vitest';
import * as fc from 'fast-check';
import {
  cosineSimilarity,
  tokenize,
  jaccardSimilarity,
  classifySimilarity,
  jaccardPreFilter,
  batchCosineSimilarity,
  type SimilarityAction,
  type JaccardPreFilter,
} from './similarity';

describe('cosineSimilarity', () => {
  describe('example-based tests', () => {
    it('returns 1.0 for identical vectors', () => {
      const v = new Float64Array([1, 2, 3]);
      expect(cosineSimilarity(v, v)).toBeCloseTo(1.0, 10);
    });

    it('returns 0.0 for orthogonal vectors', () => {
      const a = new Float64Array([1, 0, 0]);
      const b = new Float64Array([0, 1, 0]);
      expect(cosineSimilarity(a, b)).toBeCloseTo(0.0, 10);
    });

    it('returns -1.0 for opposite vectors', () => {
      const a = new Float64Array([1, 2, 3]);
      const b = new Float64Array([-1, -2, -3]);
      expect(cosineSimilarity(a, b)).toBeCloseTo(-1.0, 10);
    });

    it('computes correct similarity for angled vectors', () => {
      const a = new Float64Array([1, 0]);
      const b = new Float64Array([1, 1]);
      // cos(45°) ≈ 0.707
      expect(cosineSimilarity(a, b)).toBeCloseTo(0.707, 3);
    });

    it('handles zero vectors', () => {
      const zero = new Float64Array([0, 0, 0]);
      const nonzero = new Float64Array([1, 2, 3]);
      expect(cosineSimilarity(zero, nonzero)).toBe(0);
    });

    it('throws on dimension mismatch', () => {
      const a = new Float64Array([1, 2]);
      const b = new Float64Array([1, 2, 3]);
      expect(() => cosineSimilarity(a, b)).toThrow(/dimension mismatch/i);
    });

    it('throws on empty vectors', () => {
      const a = new Float64Array([]);
      const b = new Float64Array([]);
      expect(() => cosineSimilarity(a, b)).toThrow(/empty vectors/i);
    });
  });

  describe('property-based tests', () => {
    it('is symmetric: sim(a,b) = sim(b,a)', () => {
      fc.assert(
        fc.property(
          fc.array(fc.float({ min: -10, max: 10, noNaN: true }), { minLength: 1, maxLength: 100 }),
          fc.array(fc.float({ min: -10, max: 10, noNaN: true }), { minLength: 1, maxLength: 100 }),
          (arrA, arrB) => {
            // Ensure same length
            const len = Math.min(arrA.length, arrB.length);
            const a = new Float64Array(arrA.slice(0, len));
            const b = new Float64Array(arrB.slice(0, len));

            const simAB = cosineSimilarity(a, b);
            const simBA = cosineSimilarity(b, a);

            expect(simAB).toBeCloseTo(simBA, 10);
          }
        )
      );
    });

    it('is bounded in [-1, 1]', () => {
      fc.assert(
        fc.property(
          fc.array(fc.float({ min: -10, max: 10, noNaN: true }), { minLength: 1, maxLength: 100 }),
          fc.array(fc.float({ min: -10, max: 10, noNaN: true }), { minLength: 1, maxLength: 100 }),
          (arrA, arrB) => {
            const len = Math.min(arrA.length, arrB.length);
            const a = new Float64Array(arrA.slice(0, len));
            const b = new Float64Array(arrB.slice(0, len));

            const sim = cosineSimilarity(a, b);
            expect(sim).toBeGreaterThanOrEqual(-1.0);
            expect(sim).toBeLessThanOrEqual(1.0);
          }
        )
      );
    });

    it('returns 1.0 for identical vectors (identity property)', () => {
      fc.assert(
        fc.property(
          fc.array(fc.float({ min: -10, max: 10, noNaN: true }), { minLength: 1, maxLength: 100 }),
          (arr) => {
            const v = new Float64Array(arr);
            // Skip all-zero vectors
            if (arr.every(x => x === 0)) return;

            const sim = cosineSimilarity(v, v);
            expect(sim).toBeCloseTo(1.0, 10);
          }
        )
      );
    });
  });
});

describe('tokenize', () => {
  it('lowercases text', () => {
    expect(tokenize('Hello World')).toEqual(new Set(['hello', 'world']));
  });

  it('removes punctuation', () => {
    expect(tokenize("don't, can't! test?")).toEqual(new Set(['don', 't', 'can', 'test']));
  });

  it('collapses whitespace', () => {
    expect(tokenize('hello    world')).toEqual(new Set(['hello', 'world']));
  });

  it('handles empty string', () => {
    expect(tokenize('')).toEqual(new Set());
  });

  it('handles whitespace-only string', () => {
    expect(tokenize('   ')).toEqual(new Set());
  });

  it('trims leading/trailing whitespace', () => {
    expect(tokenize('  hello world  ')).toEqual(new Set(['hello', 'world']));
  });

  it('deduplicates repeated words', () => {
    expect(tokenize('hello hello world')).toEqual(new Set(['hello', 'world']));
  });
});

describe('jaccardSimilarity', () => {
  describe('example-based tests', () => {
    it('returns 1.0 for identical sets', () => {
      const a = new Set(['hello', 'world']);
      const b = new Set(['hello', 'world']);
      expect(jaccardSimilarity(a, b)).toBe(1.0);
    });

    it('returns 0.0 for disjoint sets', () => {
      const a = new Set(['hello']);
      const b = new Set(['world']);
      expect(jaccardSimilarity(a, b)).toBe(0.0);
    });

    it('computes partial overlap correctly', () => {
      const a = new Set(['a', 'b', 'c']);
      const b = new Set(['b', 'c', 'd']);
      // intersection = {b, c} = 2
      // union = {a, b, c, d} = 4
      expect(jaccardSimilarity(a, b)).toBe(0.5);
    });

    it('handles one empty set', () => {
      const a = new Set(['hello']);
      const b = new Set<string>();
      expect(jaccardSimilarity(a, b)).toBe(0.0);
    });

    it('handles both empty sets', () => {
      const a = new Set<string>();
      const b = new Set<string>();
      expect(jaccardSimilarity(a, b)).toBe(1.0);
    });

    it('handles subset relationship', () => {
      const a = new Set(['a', 'b']);
      const b = new Set(['a', 'b', 'c', 'd']);
      // intersection = {a, b} = 2
      // union = {a, b, c, d} = 4
      expect(jaccardSimilarity(a, b)).toBe(0.5);
    });
  });

  describe('property-based tests', () => {
    it('is symmetric: J(a,b) = J(b,a)', () => {
      fc.assert(
        fc.property(
          fc.array(fc.string(), { maxLength: 20 }),
          fc.array(fc.string(), { maxLength: 20 }),
          (arrA, arrB) => {
            const a = new Set(arrA);
            const b = new Set(arrB);

            expect(jaccardSimilarity(a, b)).toBe(jaccardSimilarity(b, a));
          }
        )
      );
    });

    it('is bounded in [0, 1]', () => {
      fc.assert(
        fc.property(
          fc.array(fc.string(), { maxLength: 20 }),
          fc.array(fc.string(), { maxLength: 20 }),
          (arrA, arrB) => {
            const a = new Set(arrA);
            const b = new Set(arrB);

            const sim = jaccardSimilarity(a, b);
            expect(sim).toBeGreaterThanOrEqual(0.0);
            expect(sim).toBeLessThanOrEqual(1.0);
          }
        )
      );
    });

    it('returns 1.0 for identical sets (identity property)', () => {
      fc.assert(
        fc.property(
          fc.array(fc.string(), { minLength: 1, maxLength: 20 }),
          (arr) => {
            const a = new Set(arr);
            expect(jaccardSimilarity(a, a)).toBe(1.0);
          }
        )
      );
    });
  });
});

describe('classifySimilarity', () => {
  it('classifies score < 0.1 as ignore', () => {
    const result = classifySimilarity(0.05);
    expect(result.type).toBe('ignore');
    expect(result.score).toBe(0.05);
  });

  it('classifies score 0.1-0.4 as relate', () => {
    expect(classifySimilarity(0.1).type).toBe('relate');
    expect(classifySimilarity(0.25).type).toBe('relate');
    expect(classifySimilarity(0.39).type).toBe('relate');
  });

  it('classifies score 0.4-0.5 as suggest', () => {
    expect(classifySimilarity(0.4).type).toBe('suggest');
    expect(classifySimilarity(0.45).type).toBe('suggest');
    expect(classifySimilarity(0.5).type).toBe('suggest');
  });

  it('classifies score > 0.5 as consolidate', () => {
    expect(classifySimilarity(0.51).type).toBe('consolidate');
    expect(classifySimilarity(0.75).type).toBe('consolidate');
    expect(classifySimilarity(1.0).type).toBe('consolidate');
  });

  it('preserves original score in result', () => {
    const score = 0.42;
    const result = classifySimilarity(score);
    expect(result.score).toBe(score);
  });

  describe('boundary tests', () => {
    it('handles boundary 0.1', () => {
      expect(classifySimilarity(0.1).type).toBe('relate');
      expect(classifySimilarity(0.09999).type).toBe('ignore');
    });

    it('handles boundary 0.4', () => {
      expect(classifySimilarity(0.4).type).toBe('suggest');
      expect(classifySimilarity(0.39999).type).toBe('relate');
    });

    it('handles boundary 0.5', () => {
      expect(classifySimilarity(0.5).type).toBe('suggest');
      expect(classifySimilarity(0.50001).type).toBe('consolidate');
    });
  });
});

describe('jaccardPreFilter', () => {
  it('returns definitely_similar for score > 0.6', () => {
    const a = new Set(['a', 'b', 'c']);
    const b = new Set(['a', 'b', 'c', 'd']); // J = 3/4 = 0.75
    const result = jaccardPreFilter(a, b);
    expect(result.result).toBe('definitely_similar');
    expect(result.score).toBe(0.75);
  });

  it('returns definitely_different for score < 0.1', () => {
    const a = new Set(['a']);
    const b = new Set(['b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k']); // J = 0/11 = 0
    const result = jaccardPreFilter(a, b);
    expect(result.result).toBe('definitely_different');
    expect(result.score).toBe(0.0);
  });

  it('returns maybe for score 0.1-0.6', () => {
    const a = new Set(['a', 'b']);
    const b = new Set(['b', 'c', 'd']); // J = 1/4 = 0.25
    const result = jaccardPreFilter(a, b);
    expect(result.result).toBe('maybe');
    expect(result.score).toBe(0.25);
  });

  describe('boundary tests', () => {
    it('handles boundary 0.6', () => {
      // Create sets with J = exactly 0.6
      const a = new Set(['a', 'b', 'c']);
      const b = new Set(['a', 'b', 'd', 'e']); // J = 2/5 = 0.4
      const result = jaccardPreFilter(a, b);
      expect(result.result).toBe('maybe');
      expect(result.score).toBe(0.4);

      // Create sets with J > 0.6
      const c = new Set(['a', 'b', 'c']);
      const d = new Set(['a', 'b', 'c', 'd']); // J = 3/4 = 0.75
      const result2 = jaccardPreFilter(c, d);
      expect(result2.result).toBe('definitely_similar');
    });

    it('handles boundary 0.1', () => {
      // Create sets with J = exactly 0.1
      const a = new Set(['a']);
      const b = new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j']); // J = 1/10 = 0.1
      const result = jaccardPreFilter(a, b);
      expect(result.result).toBe('maybe');
      expect(result.score).toBe(0.1);

      // Create sets with J < 0.1
      const c = new Set(['a']);
      const d = new Set(['b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k']); // J = 0
      const result2 = jaccardPreFilter(c, d);
      expect(result2.result).toBe('definitely_different');
    });
  });
});

describe('batchCosineSimilarity', () => {
  it('computes similarity for all targets', () => {
    const query = new Float64Array([1, 0, 0]);
    const targets = [
      new Float64Array([1, 0, 0]),    // sim = 1.0
      new Float64Array([0, 1, 0]),    // sim = 0.0
      new Float64Array([-1, 0, 0]),   // sim = -1.0
    ];

    const results = batchCosineSimilarity(query, targets);

    expect(results).toHaveLength(3);
    expect(results[0].score).toBeCloseTo(1.0, 10);
    expect(results[0].targetIndex).toBe(0);
    expect(results[1].score).toBeCloseTo(0.0, 10);
    expect(results[1].targetIndex).toBe(1);
    expect(results[2].score).toBeCloseTo(-1.0, 10);
    expect(results[2].targetIndex).toBe(2);
  });

  it('sorts results by score descending', () => {
    const query = new Float64Array([1, 0]);
    const targets = [
      new Float64Array([0, 1]),       // sim = 0.0
      new Float64Array([1, 1]),       // sim = 0.707
      new Float64Array([1, 0]),       // sim = 1.0
      new Float64Array([-1, 0]),      // sim = -1.0
    ];

    const results = batchCosineSimilarity(query, targets);

    expect(results[0].targetIndex).toBe(2); // highest (1.0)
    expect(results[1].targetIndex).toBe(1); // second (0.707)
    expect(results[2].targetIndex).toBe(0); // third (0.0)
    expect(results[3].targetIndex).toBe(3); // lowest (-1.0)
  });

  it('includes action classification for each result', () => {
    const query = new Float64Array([1, 0]);
    const targets = [
      new Float64Array([1, 0]),       // sim = 1.0 → consolidate
      new Float64Array([1, 1]),       // sim = 0.707 → consolidate
      new Float64Array([0.5, 1]),     // sim ≈ 0.45 → suggest
      new Float64Array([0.2, 1]),     // sim ≈ 0.20 → relate
      new Float64Array([0, 1]),       // sim = 0.0 → ignore
    ];

    const results = batchCosineSimilarity(query, targets);

    expect(results[0].action.type).toBe('consolidate');
    expect(results[1].action.type).toBe('consolidate');
    expect(results[2].action.type).toBe('suggest');
    expect(results[3].action.type).toBe('relate');
    expect(results[4].action.type).toBe('ignore');
  });

  it('handles empty targets array', () => {
    const query = new Float64Array([1, 0]);
    const results = batchCosineSimilarity(query, []);
    expect(results).toHaveLength(0);
  });

  it('preserves target indices after sorting', () => {
    const query = new Float64Array([1, 0]);
    const targets = [
      new Float64Array([0, 1]),       // index 0, sim = 0.0
      new Float64Array([1, 0]),       // index 1, sim = 1.0
    ];

    const results = batchCosineSimilarity(query, targets);

    // After sorting, highest score (index 1) comes first
    expect(results[0].targetIndex).toBe(1);
    expect(results[1].targetIndex).toBe(0);
  });
});

describe('integration: tokenize + jaccard workflow', () => {
  it('computes similarity between text strings', () => {
    const text1 = 'The quick brown fox jumps over the lazy dog';
    const text2 = 'A quick brown dog jumps over the lazy fox';

    const tokens1 = tokenize(text1);
    const tokens2 = tokenize(text2);
    const similarity = jaccardSimilarity(tokens1, tokens2);

    // Common: quick, brown, jumps, over, the, lazy, fox, dog = 8
    // Union: the, quick, brown, fox, jumps, over, lazy, dog, a = 9
    expect(similarity).toBeCloseTo(8 / 9, 5);
  });

  it('handles case and punctuation differences', () => {
    const text1 = 'Hello, World!';
    const text2 = 'hello world';

    const tokens1 = tokenize(text1);
    const tokens2 = tokenize(text2);
    const similarity = jaccardSimilarity(tokens1, tokens2);

    expect(similarity).toBe(1.0); // Identical after normalization
  });
});
