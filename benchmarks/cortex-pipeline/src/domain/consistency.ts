// The reference model against itself: the agreement ceiling an arm is judged by.
//
// Cortex re-asks about a pair when an earlier batch failed or the pair's
// content changed, so the corpus holds the same (source, target) pair labelled
// in two different batches. Agreement between those two labels is what "as
// good as the reference" can mean at best: a kappa an arm reaches against the
// reference cannot be expected to exceed it.

import type { SessionId } from './model.ts';
import type { LabelPair, MemoryPair, PairLabel } from './relate.ts';

export type LabelledBatch = Readonly<{
  session: SessionId;
  at: Date;
  pairs: readonly MemoryPair[];
  labels: readonly PairLabel[];
}>;

/**
 * For every pair labelled in at least two different sessions, its first two
 * labels in time order, as (earlier, later). One entry per pair, so no pair
 * weighs more for being asked often.
 */
export const repeatedPairLabels = (batches: readonly LabelledBatch[]): readonly LabelPair[] => {
  const seen = new Map<string, { session: SessionId; label: PairLabel }>();
  const out = new Map<string, LabelPair>();
  const ordered = [...batches].sort((a, b) => +a.at - +b.at || a.session.localeCompare(b.session));
  for (const batch of ordered) {
    batch.pairs.forEach((pair, i) => {
      const label = batch.labels[i];
      if (label === undefined) return;
      const key = `${pair.source.id}:${pair.target.id}`;
      if (out.has(key)) return;
      const first = seen.get(key);
      if (first === undefined) seen.set(key, { session: batch.session, label });
      else if (first.session !== batch.session) out.set(key, { reference: first.label, arm: label });
    });
  }
  return [...out.values()];
};
