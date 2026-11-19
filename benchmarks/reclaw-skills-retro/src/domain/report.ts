// Aggregation and rendering. Pure: graded runs in, Markdown out.

import { HEURISTIC_CHECKS, type Verdict, isHardFailure } from './checks.ts';
import type { CrossCheck } from './crosscheck.ts';
import { type ModelClass, type Run, durationMs, modelKey } from './model.ts';
import type { SessionError } from './session.ts';
import type { Classification } from './skill-catalog.ts';

export type GradedRun = Readonly<{ run: Run; classification: Classification; verdicts: readonly Verdict[] }>;

/** Below this many runs a rate is shown as a count, never a percentage. */
export const MIN_N = 10;

export type Interval = Readonly<{ low: number; high: number }>;

/** Wilson score interval at 95%: well-behaved at small n and at 0% or 100%. */
export const wilson = (successes: number, n: number): Interval => {
  if (n === 0) return { low: 0, high: 1 };
  const z = 1.959964;
  const p = successes / n;
  const denom = 1 + (z * z) / n;
  const centre = (p + (z * z) / (2 * n)) / denom;
  const half = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / denom;
  return { low: Math.max(0, centre - half), high: Math.min(1, centre + half) };
};

const pct = (x: number): string => `${Math.round(x * 100)}%`;

export const rateCell = (k: number, n: number): string => {
  if (n === 0) return '—';
  if (n < MIN_N) return `${k}/${n} (n<${MIN_N})`;
  const ci = wilson(k, n);
  return `${pct(k / n)} [${pct(ci.low)}–${pct(ci.high)}] (${k}/${n})`;
};

const isCompleted = (g: GradedRun): boolean => g.run.outcome.kind !== 'failed';
/** Completed with no hard failure. Heuristic flags are reported beside it, never inside it. */
const isClean = (g: GradedRun): boolean => isCompleted(g) && !g.verdicts.some(isHardFailure);
const isHeuristicallyFlagged = (g: GradedRun): boolean =>
  g.verdicts.some((v) => v.status === 'fail' && HEURISTIC_CHECKS.has(v.check));

const median = (xs: readonly number[]): number | undefined => {
  if (xs.length === 0) return undefined;
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 1 ? s[mid] : ((s[mid - 1] ?? 0) + (s[mid] ?? 0)) / 2;
};

const groupBy = <T, K>(xs: readonly T[], key: (x: T) => K): ReadonlyMap<K, readonly T[]> => {
  const m = new Map<K, T[]>();
  for (const x of xs) {
    const k = key(x);
    const list = m.get(k) ?? [];
    list.push(x);
    m.set(k, list);
  }
  return m;
};

const table = (header: readonly string[], rows: readonly (readonly string[])[]): string =>
  [
    `| ${header.join(' | ')} |`,
    `|${header.map((_, i) => (i === 0 ? '---' : '---:')).join('|')}|`,
    ...rows.map((r) => `| ${r.join(' | ')} |`),
  ].join('\n');

const ARMS: readonly ModelClass[] = ['local', 'cloud'];

const skillOf = (g: GradedRun): string => (g.classification.kind === 'skill' ? g.classification.skill : '');

const failureLabel = (g: GradedRun): string => {
  const o = g.run.outcome;
  if (o.kind !== 'failed') return o.kind;
  if (o.reason.kind !== 'provider-error') return o.reason.kind;
  return `error: ${o.reason.message.replace(/\d{3,}/g, 'N').slice(0, 48)}`;
};

/** Pass rate of one check over the runs where it applied. */
const checkRate = (runs: readonly GradedRun[], check: string): string => {
  const applied = runs.flatMap((g) => g.verdicts.filter((v) => v.check === check && v.status !== 'n/a'));
  return rateCell(applied.filter((v) => v.status === 'pass').length, applied.length);
};

export type ReportInput = Readonly<{
  generatedAt: Date;
  sessionsDir: string;
  window: Readonly<{ since: Date | null; until: Date | null }>;
  graded: readonly GradedRun[];
  parseErrors: readonly Readonly<{ file: string; error: SessionError }>[];
  crossCheck: CrossCheck;
  revisionCount: number;
  unreadableRevisions: readonly string[];
  contractSkills: readonly string[];
}>;

export const renderReport = (input: ReportInput): string => {
  const scheduled = input.graded.filter((g) => g.classification.kind === 'skill');
  const out: string[] = [];
  const day = (d: Date | null): string => (d === null ? 'open' : d.toISOString().slice(0, 10));

  out.push('# Reclaw scheduled skills: local vs cloud retrospective', '');
  out.push(
    `Generated ${input.generatedAt.toISOString()} from \`${input.sessionsDir}\`, window ${day(input.window.since)} → ${day(input.window.until)}.`,
    '',
    'Graded from recorded Pi sessions; nothing was re-run. Local and cloud ran on different days, so this compares rates, not paired outputs. Rates carry a 95% Wilson interval; cells under 10 runs show counts only.',
    '',
  );

  // ── Corpus ──
  const cls = groupBy(input.graded, (g) => g.classification.kind);
  const parseKinds = groupBy(input.parseErrors, (p) => p.error.kind);
  out.push('## Corpus', '');
  out.push(
    table(
      ['Item', 'Count'],
      [
        ['Session files parsed', String(input.graded.length)],
        ...[...parseKinds].map(([k, v]) => [`Unparsable: ${k}`, String(v.length)]),
        ['Attributed to a skill', String(cls.get('skill')?.length ?? 0)],
        ['Ambiguous between skills', String(cls.get('ambiguous')?.length ?? 0)],
        ['Unclassified (chat or unknown prompt)', String(cls.get('unclassified')?.length ?? 0)],
        ['Skill revisions read from git', String(input.revisionCount)],
        ['Unreadable skill revisions', String(input.unreadableRevisions.length)],
      ],
    ),
    '',
  );
  const cc = input.crossCheck;
  out.push(
    `**Classifier check against reclaw's own anomaly log:** ${cc.agree}/${cc.joined} joined runs agree${cc.joined > 0 ? ` (${pct(cc.agree / cc.joined)})` : ''}.`,
    ...(cc.disagree.length > 0
      ? ['', ...cc.disagree.slice(0, 15).map((d) => `- \`${d.file.split('/').at(-1)}\`: log says ${d.logged}, classified ${d.classified}`)]
      : []),
    '',
  );

  // ── Reliability ──
  out.push('## Reliability: did the run complete?', '');
  out.push('Failures here are mostly the serving box being off or switching models, not answer quality.', '');
  const byArm = groupBy(scheduled, (g) => g.run.model.class);
  out.push(
    table(
      ['Arm', 'Runs', 'Completed', 'Top failure reasons'],
      ARMS.map((arm) => {
        const runs = byArm.get(arm) ?? [];
        const fails = [...groupBy(runs.filter((g) => !isCompleted(g)), failureLabel)]
          .sort((a, b) => b[1].length - a[1].length)
          .slice(0, 3)
          .map(([k, v]) => `${k} ×${v.length}`)
          .join('; ');
        return [arm, String(runs.length), rateCell(runs.filter(isCompleted).length, runs.length), fails || '—'];
      }),
    ),
    '',
  );

  // ── Headline ──
  const completed = scheduled.filter(isCompleted);
  out.push('## Quality: clean-run rate per skill', '');
  out.push(
    `A clean run completed and failed no hard check. Heuristic checks (${[...HEURISTIC_CHECKS].join(', ')}) only flag runs for review; their counts sit beside the rate. Only completed runs are graded.`,
    '',
  );
  const bySkill = [...groupBy(completed, skillOf)].sort((a, b) => b[1].length - a[1].length);
  const armCells = (runs: readonly GradedRun[]): readonly string[] => [
    ...ARMS.map((arm) => {
      const r = runs.filter((g) => g.run.model.class === arm);
      return rateCell(r.filter(isClean).length, r.length);
    }),
    ARMS.map((arm) => {
      const r = runs.filter((g) => g.run.model.class === arm);
      return `${r.filter(isHeuristicallyFlagged).length}/${r.length}`;
    }).join(' · '),
  ];
  out.push(
    table(
      ['Skill', 'Contract', ...ARMS.map((a) => `${a} clean`), `heuristic flags (${ARMS.join(' · ')})`],
      [
        ...bySkill.map(([skill, runs]) => [
          skill,
          input.contractSkills.includes(skill) ? 'yes' : 'universal only',
          ...armCells(runs),
        ]),
        ['**all skills**', '', ...armCells(completed)],
      ],
    ),
    '',
  );

  // ── Per check ──
  const checks = [...new Set(completed.flatMap((g) => g.verdicts.map((v) => v.check)))];
  const universal = checks.filter((c) => !c.includes(':'));
  out.push('## Universal checks, all skills pooled', '');
  out.push(
    table(
      ['Check', ...ARMS],
      universal.map((c) => [
        HEURISTIC_CHECKS.has(c) ? `${c} (heuristic)` : c,
        ...ARMS.map((arm) => checkRate(completed.filter((g) => g.run.model.class === arm), c)),
      ]),
    ),
    '',
  );

  // ── Per model ──
  out.push('## Per model', '');
  const byModel = [...groupBy(scheduled, (g) => modelKey(g.run.model))].sort((a, b) => b[1].length - a[1].length);
  out.push(
    table(
      ['Model', 'Arm', 'Runs', 'Completed', 'Clean (of completed)', 'Median s', 'Median out tok'],
      byModel.map(([key, runs]) => {
        const done = runs.filter(isCompleted);
        const sec = median(done.map((g) => durationMs(g.run) / 1000));
        const tok = median(done.map((g) => g.run.usage.output));
        return [
          `\`${key}\``,
          runs[0]?.run.model.class ?? '',
          String(runs.length),
          rateCell(done.length, runs.length),
          rateCell(done.filter(isClean).length, done.length),
          sec === undefined ? '—' : String(Math.round(sec)),
          tok === undefined ? '—' : String(Math.round(tok)),
        ];
      }),
    ),
    '',
  );

  // ── Per skill detail ──
  out.push('## Per skill, per check', '');
  for (const [skill, runs] of bySkill) {
    const skillChecks = [...new Set(runs.flatMap((g) => g.verdicts.map((v) => v.check)))];
    out.push(`### ${skill}`, '');
    out.push(
      table(
        ['Check', ...ARMS],
        skillChecks.map((c) => [c, ...ARMS.map((arm) => checkRate(runs.filter((g) => g.run.model.class === arm), c))]),
      ),
      '',
    );
  }
  return out.join('\n');
};

/** Every failed verdict, one block per run, for the hand review that calibrates the graders. */
export const renderFlagged = (graded: readonly GradedRun[]): string => {
  const flagged = graded.filter(
    (g) => isCompleted(g) && g.classification.kind === 'skill' && g.verdicts.some((v) => v.status === 'fail'),
  );
  const out = [
    '# Flagged runs (hand review)',
    '',
    `${flagged.length} completed runs failed at least one check. Heuristic failures are marked; they never make a run unclean.`,
    '',
  ];
  for (const [skill, runs] of [...groupBy(flagged, skillOf)].sort()) {
    out.push(`## ${skill}`, '');
    for (const g of runs) {
      out.push(`- \`${g.run.file}\` — ${g.run.model.class} \`${modelKey(g.run.model)}\` ${g.run.startedAt.toISOString().slice(0, 16)}`);
      for (const v of g.verdicts) {
        if (v.status !== 'fail') continue;
        out.push(`  - **${v.check}**${HEURISTIC_CHECKS.has(v.check) ? ' (heuristic)' : ''}: ${v.detail}`);
      }
    }
    out.push('');
  }
  return out.join('\n');
};
