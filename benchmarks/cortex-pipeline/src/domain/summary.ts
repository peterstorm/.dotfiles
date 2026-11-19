// One arm's grades, summarised per job. Every rate carries its sample size; the
// report decides how to show small samples.

import type { ExtractionMatch } from './extract.ts';
import { FAILURE_CLASSES, type FailureClass } from './failure.ts';
import type { CaseGrade, Graded } from './grade.ts';
import { assertNever } from './model.ts';
import type { PruneAgreement } from './prune.ts';
import { type EdgeAgreement, type LabelPair, categoryKappa, edgeAgreement, edgeKappa, sameCategory } from './relate.ts';
import { type F1, type Interval, clusterBootstrap, cohenKappa, f1, percentile, wilson } from './stats.ts';

export type Reliability = Readonly<{
  cases: number;
  usable: number;
  usableInterval: Interval;
  failures: ReadonlyMap<FailureClass, number>;
  latencyP50: number | null;
  latencyP95: number | null;
  completionTokensP50: number | null;
  completionTokensP95: number | null;
}>;

export type RelateSummary = Readonly<{
  reliability: Reliability;
  pairs: number;
  exact: number;
  kappa: number | null;
  kappaInterval: Interval | null;
  edgeKappa: number | null;
  edgeKappaInterval: Interval | null;
  referenceEdges: number;
  armEdges: number;
  edges: EdgeAgreement;
}>;

export type PruneSummary = Readonly<{
  reliability: Reliability;
  memories: number;
  kappa: number | null;
  kappaInterval: Interval | null;
  /** The arm's archive set scored against the reference's. */
  archive: F1;
  referenceArchived: number;
  armArchived: number;
  nominatedGuarded: number;
}>;

export type ExtractSummary = Readonly<{
  reliability: Reliability;
  referenceMemories: number;
  armMemories: number;
  matched: number;
  sameType: number;
  /** Cases where one side extracted nothing and the other something. */
  emptinessDisagreements: number;
}>;

export type ArmSummary = Readonly<{
  relate: RelateSummary | null;
  prune: PruneSummary | null;
  extract: ExtractSummary | null;
}>;

const STATISTIC_SEED = 20261119;

const reliability = <T>(grades: readonly Graded<T>[]): Reliability => {
  const failures = new Map<FailureClass, number>();
  for (const c of FAILURE_CLASSES) failures.set(c, 0);
  const latencies: number[] = [];
  const tokens: number[] = [];
  let usable = 0;
  for (const g of grades) {
    if (g.kind === 'usable') {
      usable += 1;
      latencies.push(g.meta.latencyMs);
      if (g.meta.completionTokens !== null) tokens.push(g.meta.completionTokens);
    } else {
      failures.set(g.failure, (failures.get(g.failure) ?? 0) + 1);
      if (g.latencyMs !== null) latencies.push(g.latencyMs);
    }
  }
  return {
    cases: grades.length,
    usable,
    usableInterval: wilson(usable, grades.length),
    failures,
    latencyP50: percentile(latencies, 50),
    latencyP95: percentile(latencies, 95),
    completionTokensP50: percentile(tokens, 50),
    completionTokensP95: percentile(tokens, 95),
  };
};

const usableValues = <T>(grades: readonly Graded<T>[]): readonly T[] =>
  grades.flatMap((g) => (g.kind === 'usable' ? [g.value] : []));

export const summariseRelate = (grades: readonly Graded<readonly LabelPair[]>[]): RelateSummary => {
  const batches = usableValues(grades);
  const pairs = batches.flat();
  return {
    reliability: reliability(grades),
    pairs: pairs.length,
    exact: pairs.filter(sameCategory).length,
    kappa: categoryKappa(pairs),
    kappaInterval: clusterBootstrap(batches, categoryKappa, STATISTIC_SEED),
    edgeKappa: edgeKappa(pairs),
    edgeKappaInterval: clusterBootstrap(batches, edgeKappa, STATISTIC_SEED),
    referenceEdges: pairs.filter((p) => p.reference.kind === 'edge').length,
    armEdges: pairs.filter((p) => p.arm.kind === 'edge').length,
    edges: edgeAgreement(pairs),
  };
};

type PruneGraded = PruneAgreement & { nominatedGuarded: number };

const pruneKappa = (votes: readonly PruneAgreement['votes'][number][]): number | null => cohenKappa(votes);

export const summarisePrune = (grades: readonly Graded<PruneGraded>[]): PruneSummary => {
  const batches = usableValues(grades);
  const sum = (pick: (b: PruneGraded) => number) => batches.reduce((a, b) => a + pick(b), 0);
  const both = sum((b) => b.bothArchive);
  const referenceArchived = sum((b) => b.referenceArchive);
  const armArchived = sum((b) => b.armArchive);
  return {
    reliability: reliability(grades),
    memories: sum((b) => b.memories),
    kappa: pruneKappa(batches.flatMap((b) => b.votes)),
    kappaInterval: clusterBootstrap(batches.map((b) => b.votes), pruneKappa, STATISTIC_SEED),
    archive: f1(both, armArchived, referenceArchived),
    referenceArchived,
    armArchived,
    nominatedGuarded: sum((b) => b.nominatedGuarded),
  };
};

export const summariseExtract = (grades: readonly Graded<ExtractionMatch>[]): ExtractSummary => {
  const matches = usableValues(grades);
  const sum = (pick: (m: ExtractionMatch) => number) => matches.reduce((a, m) => a + pick(m), 0);
  return {
    reliability: reliability(grades),
    referenceMemories: sum((m) => m.referenceCount),
    armMemories: sum((m) => m.armCount),
    matched: sum((m) => m.matched),
    sameType: sum((m) => m.sameType),
    emptinessDisagreements: matches.filter((m) => (m.referenceCount === 0) !== (m.armCount === 0)).length,
  };
};

export const summariseArm = (grades: readonly CaseGrade[]): ArmSummary => {
  const relate: Graded<readonly LabelPair[]>[] = [];
  const prune: Graded<PruneGraded>[] = [];
  const extract: Graded<ExtractionMatch>[] = [];
  for (const g of grades) {
    switch (g.job) {
      case 'relate':
        relate.push(g.graded);
        break;
      case 'prune':
        prune.push(g.graded);
        break;
      case 'extract':
        extract.push(g.graded);
        break;
      default:
        assertNever(g);
    }
  }
  return {
    relate: relate.length === 0 ? null : summariseRelate(relate),
    prune: prune.length === 0 ? null : summarisePrune(prune),
    extract: extract.length === 0 ? null : summariseExtract(extract),
  };
};
