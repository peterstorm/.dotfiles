// Statistics used by the report. All pure; randomness comes from a seeded generator.

export type Interval = Readonly<{ lo: number; hi: number }>;

/** 95% Wilson score interval for k successes in n trials. */
export const wilson = (k: number, n: number): Interval => {
  if (n === 0) return { lo: 0, hi: 1 };
  const z = 1.959964;
  const p = k / n;
  const denom = 1 + (z * z) / n;
  const centre = (p + (z * z) / (2 * n)) / denom;
  const half = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / denom;
  return { lo: Math.max(0, centre - half), hi: Math.min(1, centre + half) };
};

/**
 * Cohen's kappa for two raters over the same items. Undefined (null) when the
 * expected agreement is 1 (both raters used one and the same category for
 * everything), where kappa has no meaning.
 */
export const cohenKappa = <C extends string>(pairs: readonly (readonly [C, C])[]): number | null => {
  const n = pairs.length;
  if (n === 0) return null;
  const a = new Map<C, number>();
  const b = new Map<C, number>();
  let agree = 0;
  for (const [x, y] of pairs) {
    a.set(x, (a.get(x) ?? 0) + 1);
    b.set(y, (b.get(y) ?? 0) + 1);
    if (x === y) agree += 1;
  }
  const observed = agree / n;
  let expected = 0;
  for (const [category, countA] of a) expected += (countA / n) * ((b.get(category) ?? 0) / n);
  return expected >= 1 ? null : (observed - expected) / (1 - expected);
};

export type F1 = Readonly<{ precision: number | null; recall: number | null; f1: number | null }>;

/** Precision/recall/F1 of a predicted set against a reference set, from counts. */
export const f1 = (truePositive: number, predicted: number, actual: number): F1 => {
  const precision = predicted === 0 ? null : truePositive / predicted;
  const recall = actual === 0 ? null : truePositive / actual;
  const value =
    precision === null || recall === null || precision + recall === 0
      ? null
      : (2 * precision * recall) / (precision + recall);
  return { precision, recall, f1: value };
};

/** Nearest-rank percentile (p in 0..100) of a non-empty list; null when empty. */
export const percentile = (values: readonly number[], p: number): number | null => {
  if (values.length === 0) return null;
  const sorted = [...values].sort((x, y) => x - y);
  const rank = Math.min(sorted.length, Math.max(1, Math.ceil((p / 100) * sorted.length)));
  return sorted[rank - 1] ?? null;
};

/** mulberry32: a small seeded PRNG, uniform on [0, 1). */
export const seededRandom = (seed: number): (() => number) => {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};

/**
 * 95% percentile-bootstrap interval of a statistic over clusters. Items inside
 * one batch are correlated (one model call labels them all), so whole clusters
 * are resampled, not items. Null when the statistic is undefined on the data.
 */
export const clusterBootstrap = <T>(
  clusters: readonly (readonly T[])[],
  statistic: (items: readonly T[]) => number | null,
  seed: number,
  resamples = 1000,
): Interval | null => {
  if (clusters.length === 0) return null;
  const random = seededRandom(seed);
  const values: number[] = [];
  for (let r = 0; r < resamples; r++) {
    const items: T[] = [];
    for (let i = 0; i < clusters.length; i++) {
      const pick = clusters[Math.floor(random() * clusters.length)];
      if (pick !== undefined) items.push(...pick);
    }
    const value = statistic(items);
    if (value !== null) values.push(value);
  }
  const lo = percentile(values, 2.5);
  const hi = percentile(values, 97.5);
  return lo === null || hi === null ? null : { lo, hi };
};
