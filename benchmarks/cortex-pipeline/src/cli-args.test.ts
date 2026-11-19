import { describe, expect, test } from 'bun:test';
import { DEFAULTS, parseCommand } from './cli-args.ts';

const P = '/repo/protocols';

describe('parseCommand', () => {
  test('fills defaults', () => {
    expect(parseCommand(['corpus'], P)).toEqual({
      ok: true,
      value: { kind: 'corpus', projects: DEFAULTS.projects, data: DEFAULTS.data, cortex: DEFAULTS.cortex },
    });
    expect(parseCommand(['protocol', '--name', 'v2'], P)).toMatchObject({
      ok: true,
      value: { kind: 'protocol', name: 'v2', seed: DEFAULTS.seed, quotas: DEFAULTS.quotas, out: '/repo/protocols/v2.json' },
    });
  });

  test('reads run options', () => {
    expect(
      parseCommand(['run', '--protocol', 'p.json', '--arm', 'claude:haiku', '--jobs', 'relate,prune', '--limit', '5', '--concurrency', '1'], P),
    ).toMatchObject({ ok: true, value: { kind: 'run', arm: 'claude:haiku', jobs: ['relate', 'prune'], limit: 5, concurrency: 1 } });
  });

  test('rejects what it does not know, naming the problem', () => {
    const bad: ReadonlyArray<readonly string[]> = [
      [],
      ['bench'],
      ['run', '--protocol', 'p.json'],
      ['run', '--protocol', 'p.json', '--arm', 'x', '--jobs', 'relate,summarise'],
      ['run', '--protocol', 'p.json', '--arm', 'x', '--concurrency', '0'],
      ['protocol', '--name', 'Bad Name'],
      ['protocol', '--name', 'v1', '--relate', '-3'],
      ['report', '--protocol', 'p.json', '--arm', 'x'],
      ['report', '--protocol'],
    ];
    for (const argv of bad) expect(parseCommand(argv, P).ok).toBe(false);
  });
});
