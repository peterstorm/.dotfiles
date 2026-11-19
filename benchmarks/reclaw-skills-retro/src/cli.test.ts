import { describe, expect, test } from 'bun:test';
import { parseArgs } from './cli.ts';

const NOW = new Date('2026-11-19T19:05:30.123Z');

describe('parseArgs', () => {
  test('defaults point at the reclaw sessions and a timestamped output outside git', () => {
    const r = parseArgs([], NOW);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.sessionsDir).toEndWith('--home-peterstorm-dev-claude-plugins-reclaw-workspace--');
    expect(r.value.outDir).toEndWith('.local/share/bench/reclaw-skills-retro/2026-11-19T19-05-30');
    expect(r.value.since).toBeNull();
  });

  test('a window is parsed into dates', () => {
    const r = parseArgs(['--since', '2026-09-01', '--until', '2026-10-24'], NOW);
    expect(r.ok && r.value.since?.toISOString()).toBe('2026-09-01T00:00:00.000Z');
    expect(r.ok && r.value.until?.toISOString()).toBe('2026-10-24T00:00:00.000Z');
  });

  test('bad input is a typed error, not a crash', () => {
    expect(parseArgs(['--bogus', 'x'], NOW)).toEqual({ ok: false, error: { kind: 'unknown-flag', flag: '--bogus' } });
    expect(parseArgs(['--since'], NOW)).toEqual({ ok: false, error: { kind: 'missing-value', flag: '--since' } });
    expect(parseArgs(['--since', '2026-13-45'], NOW)).toEqual({ ok: false, error: { kind: 'bad-date', flag: '--since' } });
  });
});
