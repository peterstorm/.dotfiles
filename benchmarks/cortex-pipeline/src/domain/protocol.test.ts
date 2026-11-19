import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { JOBS, type Job, SessionId } from './model.ts';
import { type Candidate, allocate, dedupeByPrompt, selectCases, spread, weekOf } from './protocol.ts';

const strataArb = fc
  .dictionary(fc.string({ minLength: 1, maxLength: 6 }), fc.integer({ min: 0, max: 50 }), { minKeys: 1, maxKeys: 12 })
  .map((d) => new Map(Object.entries(d)));

describe('allocate', () => {
  test('allocates exactly min(quota, population), never more than a stratum holds', () => {
    fc.assert(
      fc.property(strataArb, fc.integer({ min: 0, max: 400 }), (strata, quota) => {
        const population = [...strata.values()].reduce((a, b) => a + b, 0);
        const a = allocate(strata, quota);
        expect([...a.values()].reduce((x, y) => x + y, 0)).toBe(Math.min(quota, population));
        for (const [k, n] of a) expect(n).toBeLessThanOrEqual(strata.get(k) ?? 0);
      }),
    );
  });

  test('is proportional to within one case per stratum', () => {
    fc.assert(
      fc.property(strataArb, fc.integer({ min: 0, max: 400 }), (strata, quota) => {
        const population = [...strata.values()].reduce((a, b) => a + b, 0);
        fc.pre(quota < population);
        for (const [k, n] of allocate(strata, quota)) {
          expect(Math.abs(n - (quota * (strata.get(k) ?? 0)) / population)).toBeLessThan(1);
        }
      }),
    );
  });
});

const candidateArb = (job: Job): fc.Arbitrary<Candidate> =>
  fc.record({
    session: fc.uuid().map(SessionId),
    at: fc.date({ min: new Date('2026-09-01'), max: new Date('2026-11-30'), noInvalidDate: true }),
    size: fc.integer({ min: 1, max: 40 }),
    prompt: fc.string({ minLength: 1, maxLength: 4 }),
  }).map(({ session, at, size, prompt }) => ({
    call: { session, job, at, prompt, reference: { kind: 'answered', model: 'm', text: '' } },
    promptSha256: `${job}:${prompt}`,
    referenceModel: 'm',
    size,
  }));

const poolArb = fc.tuple(...JOBS.map((j) => fc.array(candidateArb(j), { maxLength: 40 }))).map((xs) => xs.flat());
const quotas = { relate: 10, prune: 5, extract: 3 };

describe('selectCases', () => {
  test('is deterministic in the seed and independent of input order', () => {
    fc.assert(
      fc.property(poolArb, fc.integer(), (pool, seed) => {
        const reversed = [...pool].reverse();
        expect(selectCases(reversed, quotas, seed)).toEqual(selectCases(pool, quotas, seed));
      }),
      { numRuns: 50 },
    );
  });

  test('meets each quota when the pool allows, with distinct prompts and sessions', () => {
    fc.assert(
      fc.property(poolArb, fc.integer(), (pool, seed) => {
        const cases = selectCases(pool, quotas, seed);
        const unique = dedupeByPrompt(pool);
        for (const job of JOBS) {
          const available = unique.filter((c) => c.call.job === job).length;
          expect(cases.filter((c) => c.job === job).length).toBe(Math.min(quotas[job], available));
        }
        expect(new Set(cases.map((c) => c.promptSha256)).size).toBe(cases.length);
      }),
      { numRuns: 50 },
    );
  });
});

describe('dedupeByPrompt', () => {
  test('keeps the earliest call of each prompt', () => {
    fc.assert(
      fc.property(fc.array(candidateArb('relate'), { maxLength: 30 }), (pool) => {
        for (const kept of dedupeByPrompt(pool)) {
          for (const other of pool) {
            if (other.promptSha256 === kept.promptSha256) expect(+kept.call.at).toBeLessThanOrEqual(+other.call.at);
          }
        }
      }),
    );
  });
});

describe('weekOf', () => {
  test('is the Monday on or before the date', () => {
    expect(weekOf(new Date('2026-11-19T22:00:00Z'))).toBe('2026-11-16'); // a Thursday
    expect(weekOf(new Date('2026-11-16T00:00:00Z'))).toBe('2026-11-16'); // a Monday
    expect(weekOf(new Date('2026-11-22T23:59:00Z'))).toBe('2026-11-16'); // a Sunday
  });
});

describe('spread', () => {
  test('takes n distinct items covering the list, or all of it', () => {
    fc.assert(
      fc.property(fc.uniqueArray(fc.integer(), { maxLength: 60 }), fc.integer({ min: 0, max: 80 }), (xs, n) => {
        const picked = spread(xs, n);
        expect(picked.length).toBe(Math.min(n, xs.length));
        expect(new Set(picked).size).toBe(picked.length);
        if (n > 0 && xs.length > 0) expect(picked[0]).toBe(xs[0]);
      }),
    );
  });
});
