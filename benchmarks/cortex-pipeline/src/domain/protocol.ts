// A protocol: the immutable list of cases every arm is run against.
//
// Cases are drawn per job, stratified by week (cortex's prompts and memory store
// change over time) and by size tertile (big batches are where truncation and
// timeouts live), with a seeded generator so the same corpus and seed always
// give the same protocol. Identical prompts are one case: cortex retries a
// failed batch with the same prompt, and a duplicate would weigh it twice.

import { JOBS, type Job, type RecordedCall, type SessionId } from './model.ts';
import { percentile, seededRandom } from './stats.ts';

/** A recorded call that may enter a protocol: its reference answered and is readable, its prompt parses. */
export type Candidate = Readonly<{
  call: RecordedCall;
  promptSha256: string;
  referenceModel: string;
  /** relate: pairs; prune: memories; extract: prompt characters. */
  size: number;
}>;

export type ProtocolCase = Readonly<{
  job: Job;
  session: SessionId;
  at: string;
  promptSha256: string;
  referenceModel: string;
  size: number;
  stratum: string;
}>;

export type Quotas = Readonly<Record<Job, number>>;

/** Monday (UTC) of the week a call was made, as `YYYY-MM-DD`. */
export const weekOf = (at: Date): string => {
  const day = (at.getUTCDay() + 6) % 7;
  const monday = new Date(Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate() - day));
  return monday.toISOString().slice(0, 10);
};

type SizeBucket = 'S' | 'M' | 'L';

const sizeBuckets = (sizes: readonly number[]): ((size: number) => SizeBucket) => {
  const q1 = percentile(sizes, 100 / 3) ?? 0;
  const q2 = percentile(sizes, 200 / 3) ?? 0;
  return (size) => (size <= q1 ? 'S' : size <= q2 ? 'M' : 'L');
};

const earlier = (a: Candidate, b: Candidate): boolean =>
  +a.call.at < +b.call.at || (+a.call.at === +b.call.at && a.call.session < b.call.session);

/** Earliest call per distinct prompt (ties: lowest session id). */
export const dedupeByPrompt = (candidates: readonly Candidate[]): readonly Candidate[] => {
  const first = new Map<string, Candidate>();
  for (const c of candidates) {
    const seen = first.get(c.promptSha256);
    if (seen === undefined || earlier(c, seen)) first.set(c.promptSha256, c);
  }
  return [...first.values()];
};

/**
 * Largest-remainder allocation of `quota` over strata in proportion to their
 * sizes. Never gives a stratum more than it holds; gives everything when the
 * quota covers the whole population. Ties go to the earlier stratum key.
 */
export const allocate = (strata: ReadonlyMap<string, number>, quota: number): ReadonlyMap<string, number> => {
  const total = [...strata.values()].reduce((a, b) => a + b, 0);
  const keys = [...strata.keys()].sort();
  if (quota >= total) return new Map(keys.map((k) => [k, strata.get(k) ?? 0]));
  const shares = keys.map((k) => {
    const exact = (quota * (strata.get(k) ?? 0)) / total;
    return { k, base: Math.floor(exact), rest: exact - Math.floor(exact) };
  });
  let left = quota - shares.reduce((a, s) => a + s.base, 0);
  const order = [...shares].sort((a, b) => b.rest - a.rest || a.k.localeCompare(b.k));
  const extra = new Set<string>();
  for (const s of order) {
    if (left === 0) break;
    if (s.base < (strata.get(s.k) ?? 0)) {
      extra.add(s.k);
      left -= 1;
    }
  }
  return new Map(shares.map((s) => [s.k, s.base + (extra.has(s.k) ? 1 : 0)]));
};

/**
 * `n` items spread evenly over a list (all of it when n covers it). A pilot run
 * on the first n cases would ask only the earliest strata; this asks across all.
 */
export const spread = <T>(items: readonly T[], n: number): readonly T[] => {
  if (n >= items.length) return items;
  return Array.from({ length: n }, (_, i) => items[Math.floor((i * items.length) / n)]).filter(
    (x): x is T => x !== undefined,
  );
};

const shuffled =<T>(items: readonly T[], random: () => number): readonly T[] => {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    const a = out[i];
    const b = out[j];
    if (a !== undefined && b !== undefined) {
      out[i] = b;
      out[j] = a;
    }
  }
  return out;
};

/**
 * The protocol's cases. Deterministic in (candidates as a set, quotas, seed):
 * input order does not matter, because each stratum is sorted by session id
 * before the seeded shuffle.
 */
export const selectCases = (candidates: readonly Candidate[], quotas: Quotas, seed: number): readonly ProtocolCase[] => {
  const random = seededRandom(seed);
  const unique = dedupeByPrompt(candidates);
  return JOBS.flatMap((job) => {
    const pool = unique.filter((c) => c.call.job === job);
    const bucket = sizeBuckets(pool.map((c) => c.size));
    const byStratum = new Map<string, Candidate[]>();
    for (const c of pool) {
      const key = `${weekOf(c.call.at)}/${bucket(c.size)}`;
      byStratum.set(key, [...(byStratum.get(key) ?? []), c]);
    }
    const allocation = allocate(new Map([...byStratum].map(([k, v]) => [k, v.length])), quotas[job]);
    return [...allocation.keys()].sort().flatMap((stratum) => {
      const members = [...(byStratum.get(stratum) ?? [])].sort((a, b) => a.call.session.localeCompare(b.call.session));
      return shuffled(members, random)
        .slice(0, allocation.get(stratum) ?? 0)
        .map((c) => ({
          job,
          session: c.call.session,
          at: c.call.at.toISOString(),
          promptSha256: c.promptSha256,
          referenceModel: c.referenceModel,
          size: c.size,
          stratum,
        }));
    });
  });
};
