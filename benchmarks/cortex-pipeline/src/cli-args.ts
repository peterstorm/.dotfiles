// Command-line parsing, pure: argv → a command, or the reason it is not one.

import { homedir } from 'node:os';
import { join } from 'node:path';
import { JOBS, type Job, type Result, err, isJob, ok } from './domain/model.ts';
import type { Quotas } from './domain/protocol.ts';

export const DEFAULTS = {
  data: join(homedir(), '.local/share/bench/cortex-pipeline'),
  cortex: join(homedir(), '.dotfiles/.claude/local-marketplace/plugins/cortex'),
  projects: join(homedir(), '.claude/projects'),
  quotas: { relate: 300, prune: 100, extract: 50 } satisfies Quotas,
  seed: 20261119,
  concurrency: 2,
} as const;

type Common = Readonly<{ data: string; cortex: string }>;

export type Command = Readonly<
  | ({ kind: 'corpus'; projects: string } & Common)
  | ({ kind: 'protocol'; name: string; seed: number; quotas: Quotas; out: string } & Common)
  | ({ kind: 'run'; protocol: string; arm: string; concurrency: number; jobs: readonly Job[]; limit: number | null } & Common)
  | ({ kind: 'report'; protocol: string; arms: readonly string[] | null } & Common)
>;

export type ArgError = Readonly<{ kind: 'usage'; message: string }>;

export const USAGE = `usage:
  bun src/cli.ts corpus   [--projects DIR] [--data DIR]
  bun src/cli.ts protocol --name NAME [--seed N] [--relate N] [--prune N] [--extract N] [--out FILE] [--cortex DIR] [--data DIR]
  bun src/cli.ts run      --protocol FILE --arm SPEC [--concurrency N] [--jobs relate,prune,extract] [--limit N] [--cortex DIR] [--data DIR]
  bun src/cli.ts report   --protocol FILE [--arms SPEC,SPEC] [--cortex DIR] [--data DIR]

arm SPEC: direct:<provider>/<model>[+unguided] | claude:<model> | pi:<provider>/<model>`;

const usage = (message: string) => err({ kind: 'usage', message } as const);

const flags = (argv: readonly string[]): Result<ReadonlyMap<string, string>, ArgError> => {
  const out = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (flag === undefined || !flag.startsWith('--')) return usage(`expected a --flag, got '${flag ?? ''}'`);
    if (value === undefined || value.startsWith('--')) return usage(`${flag} needs a value`);
    out.set(flag.slice(2), value);
  }
  return ok(out);
};

const count = (raw: string | undefined, fallback: number, name: string): Result<number, ArgError> => {
  if (raw === undefined) return ok(fallback);
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 ? ok(n) : usage(`--${name} must be a whole number, got '${raw}'`);
};

const KNOWN: Readonly<Record<Command['kind'], readonly string[]>> = {
  corpus: ['projects', 'data', 'cortex'],
  protocol: ['name', 'seed', 'relate', 'prune', 'extract', 'out', 'data', 'cortex'],
  run: ['protocol', 'arm', 'concurrency', 'jobs', 'limit', 'data', 'cortex'],
  report: ['protocol', 'arms', 'data', 'cortex'],
};

const isCommandKind = (s: string): s is Command['kind'] => Object.hasOwn(KNOWN, s);

export const parseCommand = (argv: readonly string[], protocolsDir: string): Result<Command, ArgError> => {
  const [kind, ...rest] = argv;
  if (kind === undefined || !isCommandKind(kind)) return usage(`unknown command '${kind ?? ''}'`);
  const parsed = flags(rest);
  if (!parsed.ok) return parsed;
  const f = parsed.value;
  const unknown = [...f.keys()].filter((k) => !KNOWN[kind].includes(k));
  if (unknown.length > 0) return usage(`unknown flag --${unknown[0]} for ${kind}`);
  const common: Common = { data: f.get('data') ?? DEFAULTS.data, cortex: f.get('cortex') ?? DEFAULTS.cortex };

  if (kind === 'corpus') return ok({ kind, projects: f.get('projects') ?? DEFAULTS.projects, ...common });

  if (kind === 'protocol') {
    const name = f.get('name');
    if (name === undefined || !/^[a-z0-9-]+$/.test(name)) return usage('--name is required: lowercase letters, digits, dashes');
    const seed = count(f.get('seed'), DEFAULTS.seed, 'seed');
    const relate = count(f.get('relate'), DEFAULTS.quotas.relate, 'relate');
    const prune = count(f.get('prune'), DEFAULTS.quotas.prune, 'prune');
    const extract = count(f.get('extract'), DEFAULTS.quotas.extract, 'extract');
    if (!seed.ok) return seed;
    if (!relate.ok) return relate;
    if (!prune.ok) return prune;
    if (!extract.ok) return extract;
    return ok({
      kind,
      name,
      seed: seed.value,
      quotas: { relate: relate.value, prune: prune.value, extract: extract.value },
      out: f.get('out') ?? join(protocolsDir, `${name}.json`),
      ...common,
    });
  }

  const protocol = f.get('protocol');
  if (protocol === undefined) return usage('--protocol is required');

  if (kind === 'run') {
    const arm = f.get('arm');
    if (arm === undefined) return usage('--arm is required');
    const concurrency = count(f.get('concurrency'), DEFAULTS.concurrency, 'concurrency');
    if (!concurrency.ok) return concurrency;
    if (concurrency.value < 1) return usage('--concurrency must be at least 1');
    const limitRaw = f.get('limit');
    const limit = limitRaw === undefined ? ok(null) : count(limitRaw, 0, 'limit');
    if (!limit.ok) return limit;
    const jobList = (f.get('jobs') ?? JOBS.join(',')).split(',');
    const jobs = jobList.filter(isJob);
    if (jobs.length !== jobList.length) return usage(`--jobs takes ${JOBS.join(', ')}`);
    return ok({ kind, protocol, arm, concurrency: concurrency.value, jobs, limit: limit.value, ...common });
  }

  const arms = f.get('arms');
  return ok({ kind, protocol, arms: arms === undefined ? null : arms.split(','), ...common });
};
