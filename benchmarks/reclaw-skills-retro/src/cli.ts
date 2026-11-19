#!/usr/bin/env bun
// Shell orchestrator: load skill history, stream session files through the pure
// core (parse → classify → grade), then render and persist the report.
//
//   bun src/cli.ts [--sessions DIR] [--reclaw-repo DIR] [--quality-log FILE]
//                  [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--out DIR]
//
// Output lands outside git by default: the runs contain personal data.

import { mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { grade } from './domain/checks.ts';
import { contractFor, CONTRACTS } from './domain/contracts.ts';
import { crossCheck } from './domain/crosscheck.ts';
import { type Result, type Run, durationMs, err, modelKey, ok } from './domain/model.ts';
import { type GradedRun, renderFlagged, renderReport } from './domain/report.ts';
import { type SessionError, parseSession } from './domain/session.ts';
import { buildCatalog, classify } from './domain/skill-catalog.ts';
import { listSessionFiles, readSessionFile } from './infra/pi-sessions.ts';
import { loadQualityLog } from './infra/quality-log.ts';
import { loadSkillHistory } from './infra/skill-history.ts';

export type Options = Readonly<{
  sessionsDir: string;
  reclawRepo: string;
  qualityLog: string;
  since: Date | null;
  until: Date | null;
  outDir: string;
}>;

const HOME = homedir();
const DEFAULTS = {
  sessionsDir: join(HOME, '.pi/agent/sessions/--home-peterstorm-dev-claude-plugins-reclaw-workspace--'),
  reclawRepo: join(HOME, 'dev/claude-plugins/reclaw'),
  qualityLog: join(HOME, '.cache/reclaw/skill-quality.jsonl'),
  outRoot: join(HOME, '.local/share/bench/reclaw-skills-retro'),
};

export type ArgError = Readonly<{ kind: 'unknown-flag' | 'missing-value' | 'bad-date'; flag: string }>;

const parseDay = (flag: string, raw: string): Result<Date, ArgError> => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) return err({ kind: 'bad-date', flag });
  const d = new Date(`${raw}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? err({ kind: 'bad-date', flag }) : ok(d);
};

export const parseArgs = (argv: readonly string[], now: Date): Result<Options, ArgError> => {
  const values = new Map<string, string>();
  const flags = ['--sessions', '--reclaw-repo', '--quality-log', '--since', '--until', '--out'];
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i] ?? '';
    if (!flags.includes(flag)) return err({ kind: 'unknown-flag', flag });
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) return err({ kind: 'missing-value', flag });
    values.set(flag, value);
  }
  const date = (flag: string): Result<Date | null, ArgError> => {
    const raw = values.get(flag);
    return raw === undefined ? ok(null) : parseDay(flag, raw);
  };
  const since = date('--since');
  if (!since.ok) return since;
  const until = date('--until');
  if (!until.ok) return until;
  const stamp = now.toISOString().replace(/[:.]/g, '-').slice(0, 19);
  return ok({
    sessionsDir: values.get('--sessions') ?? DEFAULTS.sessionsDir,
    reclawRepo: values.get('--reclaw-repo') ?? DEFAULTS.reclawRepo,
    qualityLog: values.get('--quality-log') ?? DEFAULTS.qualityLog,
    since: since.value,
    until: until.value,
    outDir: values.get('--out') ?? join(DEFAULTS.outRoot, stamp),
  });
};

/** A graded run keeps only what the report reads; prompts and tool output stay on disk. */
const slim = (run: Run): Run => ({ ...run, prompt: '', evidence: [] });

const inWindow = (run: Run, o: Options): boolean =>
  (o.since === null || run.startedAt >= o.since) && (o.until === null || run.startedAt < o.until);

const runRecord = (g: GradedRun): string =>
  JSON.stringify({
    file: g.run.file,
    sessionId: g.run.sessionId,
    startedAt: g.run.startedAt.toISOString(),
    durationMs: durationMs(g.run),
    skill: g.classification.kind === 'skill' ? g.classification.skill : g.classification.kind,
    revision: g.classification.kind === 'skill' ? g.classification.revision.commit.slice(0, 8) : null,
    model: modelKey(g.run.model),
    class: g.run.model.class,
    mixedModels: g.run.mixedModels,
    thinkingLevel: g.run.thinkingLevel,
    outcome: g.run.outcome,
    usage: g.run.usage,
    verdicts: g.verdicts,
  });

const main = (options: Options): void => {
  const history = loadSkillHistory(options.reclawRepo);
  const catalog = buildCatalog(history.revisions);

  const graded: GradedRun[] = [];
  const parseErrors: { file: string; error: SessionError }[] = [];
  for (const file of listSessionFiles(options.sessionsDir)) {
    const { content } = readSessionFile(file);
    const parsed = parseSession(file, content);
    if (!parsed.ok) {
      parseErrors.push({ file, error: parsed.error });
      continue;
    }
    const run = parsed.value;
    if (!inWindow(run, options)) continue;
    const classification = classify(catalog, run.prompt, run.startedAt);
    const verdicts =
      classification.kind === 'skill' ? grade(run, classification.revision, contractFor(classification.skill)) : [];
    graded.push({ run: slim(run), classification, verdicts });
  }

  const report = renderReport({
    generatedAt: new Date(),
    sessionsDir: options.sessionsDir,
    window: { since: options.since, until: options.until },
    graded,
    parseErrors,
    crossCheck: crossCheck(graded, loadQualityLog(options.qualityLog)),
    revisionCount: history.revisions.length,
    unreadableRevisions: history.unreadable,
    contractSkills: CONTRACTS.map((c) => c.skill),
  });

  mkdirSync(options.outDir, { recursive: true });
  writeFileSync(join(options.outDir, 'report.md'), report);
  writeFileSync(join(options.outDir, 'flagged.md'), renderFlagged(graded));
  writeFileSync(join(options.outDir, 'runs.jsonl'), `${graded.map(runRecord).join('\n')}\n`);
  process.stdout.write(`${graded.length} runs graded, ${parseErrors.length} unparsable → ${options.outDir}\n`);
};

if (import.meta.main) {
  const options = parseArgs(Bun.argv.slice(2), new Date());
  if (!options.ok) {
    console.error(`usage error: ${options.error.kind} ${options.error.flag}`);
    process.exit(2);
  }
  main(options.value);
}
