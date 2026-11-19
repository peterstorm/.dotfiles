import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { clusterBootstrap, cohenKappa, f1, percentile, seededRandom, wilson } from './stats.ts';

describe('wilson', () => {
  test('brackets the observed rate inside [0, 1]', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 5000 }), fc.double({ min: 0, max: 1, noNaN: true }), (n, share) => {
        const k = Math.round(share * n);
        const { lo, hi } = wilson(k, n);
        expect(lo).toBeGreaterThanOrEqual(0);
        expect(hi).toBeLessThanOrEqual(1);
        expect(lo).toBeLessThanOrEqual(k / n + 1e-12);
        expect(hi).toBeGreaterThanOrEqual(k / n - 1e-12);
      }),
    );
  });

  test('narrows as n grows at a fixed rate', () => {
    const width = (n: number) => {
      const i = wilson(n / 2, n);
      return i.hi - i.lo;
    };
    expect(width(1000)).toBeLessThan(width(100));
  });
});

const category = fc.constantFrom('a', 'b', 'c');

describe('cohenKappa', () => {
  test('is 1 for perfect agreement over at least two categories', () => {
    fc.assert(
      fc.property(fc.array(category, { minLength: 2 }), (xs) => {
        fc.pre(new Set(xs).size > 1);
        expect(cohenKappa(xs.map((x) => [x, x] as const))).toBeCloseTo(1, 10);
      }),
    );
  });

  test('is symmetric in the two raters and at most 1', () => {
    fc.assert(
      fc.property(fc.array(fc.tuple(category, category), { minLength: 1 }), (pairs) => {
        const k = cohenKappa(pairs);
        const swapped = cohenKappa(pairs.map(([x, y]) => [y, x] as const));
        if (k === null) expect(swapped).toBeNull();
        else {
          expect(swapped).toBeCloseTo(k, 10);
          expect(k).toBeLessThanOrEqual(1 + 1e-12);
        }
      }),
    );
  });

  test('is undefined when both raters used one category throughout', () => {
    expect(cohenKappa([['a', 'a'] as const, ['a', 'a'] as const])).toBeNull();
    expect(cohenKappa([])).toBeNull();
  });

  test('matches a hand-computed value', () => {
    // 20 items: both yes 10, both no 5, ref yes/arm no 3, ref no/arm yes 2.
    const pairs = [
      ...Array(10).fill(['y', 'y'] as const),
      ...Array(5).fill(['n', 'n'] as const),
      ...Array(3).fill(['y', 'n'] as const),
      ...Array(2).fill(['n', 'y'] as const),
    ];
    // po = 0.75; pe = 0.65*0.6 + 0.35*0.4 = 0.53; kappa = 0.22/0.47
    expect(cohenKappa(pairs)).toBeCloseTo(0.22 / 0.47, 10);
  });
});

describe('f1', () => {
  test('is undefined without predictions or without actual positives', () => {
    expect(f1(0, 0, 5)).toEqual({ precision: null, recall: 0, f1: null });
    expect(f1(0, 3, 0)).toEqual({ precision: 0, recall: null, f1: null });
  });

  test('lies between precision and recall', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 100 }), fc.integer({ min: 1, max: 100 }), fc.integer({ min: 0, max: 100 }), (p, a, t) => {
        const tp = Math.min(t, p, a);
        const r = f1(tp, p, a);
        if (r.f1 === null || r.precision === null || r.recall === null) return;
        expect(r.f1).toBeGreaterThanOrEqual(Math.min(r.precision, r.recall) - 1e-12);
        expect(r.f1).toBeLessThanOrEqual(Math.max(r.precision, r.recall) + 1e-12);
      }),
    );
  });
});

describe('percentile', () => {
  test('is a member of the list, between its min and max', () => {
    fc.assert(
      fc.property(fc.array(fc.integer(), { minLength: 1 }), fc.integer({ min: 0, max: 100 }), (xs, p) => {
        const v = percentile(xs, p);
        expect(xs).toContain(v as number);
      }),
    );
    expect(percentile([], 50)).toBeNull();
    expect(percentile([1, 2, 3, 4], 50)).toBe(2);
    expect(percentile([1, 2, 3, 4], 100)).toBe(4);
  });
});

describe('seeded randomness', () => {
  test('the same seed gives the same sequence, in [0, 1)', () => {
    const a = seededRandom(42);
    const b = seededRandom(42);
    for (let i = 0; i < 100; i++) {
      const x = a();
      expect(x).toBe(b());
      expect(x).toBeGreaterThanOrEqual(0);
      expect(x).toBeLessThan(1);
    }
  });

  test('cluster bootstrap is deterministic and brackets a constant statistic', () => {
    const clusters = [[1, 2], [3], [4, 5, 6]];
    const mean = (xs: readonly number[]) => (xs.length === 0 ? null : xs.reduce((a, b) => a + b, 0) / xs.length);
    expect(clusterBootstrap(clusters, mean, 9)).toEqual(clusterBootstrap(clusters, mean, 9));
    expect(clusterBootstrap(clusters, () => 0.5, 9)).toEqual({ lo: 0.5, hi: 0.5 });
    expect(clusterBootstrap([], mean, 9)).toBeNull();
  });
});
