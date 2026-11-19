// The report: corpus health, the reference's agreement with itself, then each
// job's table with one row per arm, then the proposed gate.

import { FAILURE_CLASSES } from './failure.ts';
import { JOBS, type Job } from './model.ts';
import { type LabelPair, categoryKappa, edgeKappa, sameCategory } from './relate.ts';
import { type Interval, clusterBootstrap } from './stats.ts';
import type { ArmSummary, ExtractSummary, PruneSummary, RelateSummary, Reliability } from './summary.ts';

export type JobHealth = Readonly<{
  calls: number;
  referenceFailed: number;
  promptUnparseable: number;
  referenceUnusable: number;
  eligible: number;
  referenceModels: ReadonlyMap<string, number>;
}>;

export type ArmReport = Readonly<{
  arm: string;
  summary: ArmSummary;
  cortexCommits: readonly string[];
  servedModels: readonly string[];
}>;

export type ReportInput = Readonly<{
  protocolId: string;
  cases: Readonly<Record<Job, number>>;
  health: Readonly<Record<Job, JobHealth>>;
  referenceSelfAgreement: readonly LabelPair[];
  arms: readonly ArmReport[];
  generatedAt: Date;
}>;

/** Below this many usable cases a rate is shown as counts only. */
export const MIN_N = 10;

/**
 * The proposed gate; a starting point, not a decision. Relate agreement is
 * judged against the reference's agreement with itself, not a fixed number: the
 * coverage note's κ ≥ 0.7 turned out to be above what the reference reaches
 * against itself (κ 0.60 on the first corpus), a bar no arm could be expected to clear.
 */
export const GATE = { usable: 0.99, extractP95Ms: 30_000 } as const;

type SelfAgreement = Readonly<{ pairs: number; exact: number; kappa: number | null; kappaInterval: Interval | null; edgeKappa: number | null; edgeKappaInterval: Interval | null }>;

const SELF_SEED = 7;

/** One pair per cluster: each repeated pair is an independent observation. */
export const selfAgreement = (pairs: readonly LabelPair[]): SelfAgreement => {
  const clusters = pairs.map((p) => [p]);
  return {
    pairs: pairs.length,
    exact: pairs.filter(sameCategory).length,
    kappa: categoryKappa(pairs),
    kappaInterval: clusterBootstrap(clusters, categoryKappa, SELF_SEED),
    edgeKappa: edgeKappa(pairs),
    edgeKappaInterval: clusterBootstrap(clusters, edgeKappa, SELF_SEED),
  };
};

const pct = (x: number | null): string => (x === null ? '—' : `${(x * 100).toFixed(1)}%`);
const num = (x: number | null, digits = 2): string => (x === null ? '—' : x.toFixed(digits));
const interval = (i: Interval | null, digits = 2): string => (i === null ? '' : ` [${i.lo.toFixed(digits)}–${i.hi.toFixed(digits)}]`);
const seconds = (ms: number | null): string => (ms === null ? '—' : `${(ms / 1000).toFixed(1)} s`);
const ratio = (k: number, n: number): string => (n === 0 ? '—' : `${k}/${n} (${pct(k / n)})`);

const usable = (r: Reliability): string =>
  r.cases < MIN_N
    ? `${r.usable}/${r.cases}`
    : `${r.usable}/${r.cases} (${pct(r.usable / r.cases)}${interval({ lo: r.usableInterval.lo * 100, hi: r.usableInterval.hi * 100 }, 0)})`;

const failures = (r: Reliability): string => {
  const parts = FAILURE_CLASSES.flatMap((c) => {
    const n = r.failures.get(c) ?? 0;
    return n === 0 ? [] : [`${c} ${n}`];
  });
  return parts.length === 0 ? '—' : parts.join(', ');
};

const latency = (r: Reliability): string => `${seconds(r.latencyP50)} / ${seconds(r.latencyP95)}`;
const tokens = (r: Reliability): string =>
  r.completionTokensP50 === null ? '—' : `${r.completionTokensP50} / ${r.completionTokensP95 ?? '—'}`;

const table = (header: readonly string[], rows: readonly (readonly string[])[]): string =>
  [`| ${header.join(' | ')} |`, `|${header.map(() => '---').join('|')}|`, ...rows.map((r) => `| ${r.join(' | ')} |`)].join('\n');

const healthSection = (input: ReportInput): string => {
  const rows = JOBS.map((job) => {
    const h = input.health[job];
    const models = [...h.referenceModels].sort((a, b) => b[1] - a[1]).map(([m, n]) => `${m} ${n}`).join(', ');
    return [
      job,
      String(h.calls),
      ratio(h.referenceFailed, h.calls),
      ratio(h.referenceUnusable, h.calls - h.referenceFailed - h.promptUnparseable),
      String(h.promptUnparseable),
      String(h.eligible),
      String(input.cases[job]),
      models || '—',
    ];
  });
  return [
    '## Corpus and reference health',
    '',
    'Every recorded cortex call in the Claude session store. *Reference failed*: the API call itself failed (quota, limit). ' +
      "*Reference unusable*: the answer arrived but cortex's own parser rejected it, so production retried the batch. " +
      'That is the reference model\'s failure rate in production, the baseline for an arm\'s.',
    '',
    table(['Job', 'Calls', 'Reference failed', 'Reference unusable', 'Prompt unparseable', 'Eligible', 'Cases', 'Reference model'], rows),
  ].join('\n');
};

const selfAgreementSection = (s: SelfAgreement): string =>
  [
    '## The reference against itself (relate)',
    '',
    'The same memory pair, labelled by the reference model in two different batches. No arm can be expected to agree ' +
      "with the reference more than the reference agrees with itself; read the arms' kappas against this ceiling.",
    '',
    table(
      ['Pairs', 'Exact', 'κ (8-class)', 'edge κ'],
      [[String(s.pairs), ratio(s.exact, s.pairs), `${num(s.kappa)}${interval(s.kappaInterval)}`, `${num(s.edgeKappa)}${interval(s.edgeKappaInterval)}`]],
    ),
  ].join('\n');

const relateRow = (arm: string, s: RelateSummary): readonly string[] => [
  arm,
  usable(s.reliability),
  failures(s.reliability),
  String(s.pairs),
  `${num(s.kappa)}${interval(s.kappaInterval)}`,
  `${num(s.edgeKappa)}${interval(s.edgeKappaInterval)}`,
  ratio(s.exact, s.pairs),
  `${s.referenceEdges} / ${s.armEdges}`,
  ratio(s.edges.sameRelation, s.edges.bothEdge),
  ratio(s.edges.sameBand, s.edges.sameRelation),
  latency(s.reliability),
  tokens(s.reliability),
];

const pruneRow = (arm: string, s: PruneSummary): readonly string[] => [
  arm,
  usable(s.reliability),
  failures(s.reliability),
  String(s.memories),
  `${num(s.kappa)}${interval(s.kappaInterval)}`,
  pct(s.archive.precision),
  pct(s.archive.recall),
  num(s.archive.f1),
  `${s.referenceArchived} / ${s.armArchived}`,
  String(s.nominatedGuarded),
  latency(s.reliability),
  tokens(s.reliability),
];

const extractRow = (arm: string, s: ExtractSummary): readonly string[] => [
  arm,
  usable(s.reliability),
  failures(s.reliability),
  `${s.referenceMemories} / ${s.armMemories}`,
  ratio(s.matched, s.referenceMemories),
  ratio(s.matched, s.armMemories),
  ratio(s.sameType, s.matched),
  String(s.emptinessDisagreements),
  latency(s.reliability),
  tokens(s.reliability),
];

const jobSection = <S>(
  title: string,
  explanation: string,
  header: readonly string[],
  arms: readonly ArmReport[],
  pick: (s: ArmSummary) => S | null,
  row: (arm: string, s: S) => readonly string[],
): string => {
  const rows = arms.flatMap((a) => {
    const s = pick(a.summary);
    return s === null ? [] : [row(a.arm, s)];
  });
  return [`## ${title}`, '', explanation, '', rows.length === 0 ? '_No arm has answered this job yet._' : table(header, rows)].join('\n');
};

type Check = 'pass' | 'FAIL' | 'n/a';
const check = (value: number | null, ok: (v: number) => boolean): Check => (value === null ? 'n/a' : ok(value) ? 'pass' : 'FAIL');
const rate = (r: Reliability): number | null => (r.cases === 0 ? null : r.usable / r.cases);

const gateSection = (arms: readonly ArmReport[], self: SelfAgreement): string => {
  const floor = self.kappaInterval?.lo ?? null;
  const rows = arms.map((a) => {
    const { relate, prune, extract } = a.summary;
    return [
      a.arm,
      relate === null ? 'n/a' : check(rate(relate.reliability), (v) => v >= GATE.usable),
      relate === null || floor === null ? 'n/a' : check(relate.kappa, (v) => v >= floor),
      prune === null ? 'n/a' : check(rate(prune.reliability), (v) => v >= GATE.usable),
      extract === null ? 'n/a' : check(rate(extract.reliability), (v) => v >= GATE.usable),
      extract === null ? 'n/a' : check(extract.reliability.latencyP95, (v) => v <= GATE.extractP95Ms),
    ];
  });
  return [
    '## Proposed gate',
    '',
    `Usable answers ≥ ${pct(GATE.usable)} on every job; relate κ against the reference ≥ ${num(floor)}, the lower ` +
      'bound of the reference\'s agreement with itself (an arm as consistent with the reference as the reference is with itself); ' +
      `extraction p95 ≤ ${seconds(GATE.extractP95Ms)} (cortex FR-009). A starting point, not a decision. ` +
      'Adjudicated accuracy (is the arm wrong, or only different?) is not measured by this report.',
    '',
    table(['Arm', 'relate usable', 'relate κ', 'prune usable', 'extract usable', 'extract p95'], rows),
  ].join('\n');
};

export const renderReport = (input: ReportInput): string => {
  const self = selfAgreement(input.referenceSelfAgreement);
  return [
    `# Cortex pipeline benchmark — ${input.protocolId}`,
    '',
    `Generated ${input.generatedAt.toISOString()}. Cases: relate ${input.cases.relate}, prune ${input.cases.prune}, ` +
      `extract ${input.cases.extract}. Rates show a 95% interval (Wilson for rates, cluster bootstrap over batches for κ); ` +
      `under ${MIN_N} cases, counts only. Latency and output tokens are p50 / p95.`,
    '',
    table(
      ['Arm', 'Cortex', 'Served model'],
      input.arms.map((a) => [a.arm, a.cortexCommits.join(', '), a.servedModels.join(', ') || '— (CLI)']),
    ),
    '',
    healthSection(input),
    '',
    selfAgreementSection(self),
    '',
    jobSection(
      'Relate — classify memory pairs',
      'κ over the 8 categories (no edge + 7 relations) and over edge / no edge, pair by pair against the reference. ' +
        '*Same relation*: of pairs both call an edge. *Same band*: of those, same strength band (weak/moderate/strong).',
      ['Arm', 'Usable', 'Failures', 'Pairs', 'κ', 'edge κ', 'Exact', 'Edges ref / arm', 'Same relation', 'Same band', 'Latency', 'Out tokens'],
      input.arms,
      (s) => s.relate,
      relateRow,
    ),
    '',
    jobSection(
      'Prune — choose memories to archive',
      "Decisions after cortex's code guards, as production applies them. κ over archive/keep per memory; precision and " +
        "recall of the arm's archive set against the reference's. *Guarded*: memories the arm named that the prompt " +
        'forbids archiving (pinned, stable, too young): instruction-following, kept anyway by the guards.',
      ['Arm', 'Usable', 'Failures', 'Memories', 'κ', 'Precision', 'Recall', 'F1', 'Archived ref / arm', 'Guarded', 'Latency', 'Out tokens'],
      input.arms,
      (s) => s.prune,
      pruneRow,
    ),
    '',
    jobSection(
      'Extract — transcript to memories',
      'Soft match: each reference memory pairs with at most one arm memory by word overlap of summary and content ' +
        '(Jaccard ≥ 0.2). A proxy for fact recall and precision, uncalibrated: read it as direction, and the flagged file for substance.',
      ['Arm', 'Usable', 'Failures', 'Memories ref / arm', 'Soft recall', 'Soft precision', 'Same type', 'Empty vs not', 'Latency', 'Out tokens'],
      input.arms,
      (s) => s.extract,
      extractRow,
    ),
    '',
    gateSection(input.arms, self),
    '',
  ].join('\n');
};
