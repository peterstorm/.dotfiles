import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { MIN_N, rateCell, wilson } from './report.ts';

describe('wilson', () => {
  test('property: the interval lies in [0,1] and contains the observed rate', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 5000 }), fc.nat(), (n, k0) => {
        const k = k0 % (n + 1);
        const { low, high } = wilson(k, n);
        expect(low).toBeGreaterThanOrEqual(0);
        expect(high).toBeLessThanOrEqual(1);
        expect(low).toBeLessThanOrEqual(k / n + 1e-12);
        expect(high).toBeGreaterThanOrEqual(k / n - 1e-12);
      }),
    );
  });

  test('property: more evidence at the same rate never widens the interval', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 200 }), fc.nat(), fc.integer({ min: 2, max: 10 }), (n, k0, m) => {
        const k = k0 % (n + 1);
        const a = wilson(k, n);
        const b = wilson(k * m, n * m);
        expect(b.high - b.low).toBeLessThanOrEqual(a.high - a.low + 1e-12);
      }),
    );
  });
});

describe('rateCell', () => {
  test('small samples show counts, never percentages', () => {
    expect(rateCell(3, MIN_N - 1)).toBe(`3/${MIN_N - 1} (n<${MIN_N})`);
    expect(rateCell(0, 0)).toBe('—');
    expect(rateCell(10, 10)).toMatch(/^100% \[\d+%–100%\] \(10\/10\)$/);
  });
});
