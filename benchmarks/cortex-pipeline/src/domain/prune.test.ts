import { describe, expect, test } from 'bun:test';
import { type GuardOf, type PruneRow, asCurrentPruneAnswer, decide, parsePrunePrompt, pruneAgreement } from './prune.ts';

const HEAD = "You are a memory pruner for a developer's persistent memory system.\nRules…\n\nMEMORIES:\n";

describe('parsePrunePrompt', () => {
  test('reads rows, the PIN marker and a summary that spans two lines', () => {
    const prompt =
      HEAD +
      'id-1 | decision | conf=0.85 | acc=3 | PIN | 2026-10-01 | Pinned decision.\n' +
      'id-2 | gotcha | conf=0.40 | acc=0 | 2026-10-02 | First line\nsecond line';
    expect(parsePrunePrompt(prompt)).toEqual({
      ok: true,
      value: [
        { id: 'id-1', memory_type: 'decision', confidence: 0.85, access_count: 3, pinned: true, created_day: '2026-10-01', summary: 'Pinned decision.' },
        { id: 'id-2', memory_type: 'gotcha', confidence: 0.4, access_count: 0, pinned: false, created_day: '2026-10-02', summary: 'First line\nsecond line' },
      ],
    });
  });

  test('keeps " | " inside a summary', () => {
    const parsed = parsePrunePrompt(`${HEAD}id-1 | context | conf=0.50 | acc=1 | 2026-10-01 | a | b`);
    expect(parsed.ok && parsed.value[0]?.summary).toBe('a | b');
  });

  test('rejects a prompt without rows', () => {
    expect(parsePrunePrompt('no memories here').ok).toBe(false);
    expect(parsePrunePrompt(`${HEAD}not a row`).ok).toBe(false);
  });
});

const row = (id: string, overrides: Partial<PruneRow> = {}): PruneRow => ({
  id,
  memory_type: 'context',
  confidence: 0.5,
  access_count: 0,
  pinned: false,
  created_day: '2026-10-01',
  summary: id,
  ...overrides,
});

const guardPinned: GuardOf = (r) => (r.pinned ? 'pinned' : null);
const NOW = new Date('2026-11-01T00:00:00Z');

describe('decide', () => {
  test('rejects the whole batch when an answer names an id not in it, as production does', () => {
    expect(decide([row('a')], ['a', 'ghost'], guardPinned, NOW)).toEqual({ kind: 'rejected', unknownIds: ['ghost'] });
  });

  test('archives what the guards allow and counts the guarded nominations', () => {
    const d = decide([row('a'), row('b', { pinned: true }), row('c')], ['a', 'b', 'a'], guardPinned, NOW);
    expect(d.kind).toBe('decided');
    if (d.kind === 'decided') {
      expect([...d.archived]).toEqual(['a']);
      expect(d.nominatedGuarded).toBe(1);
    }
  });
});

describe('asCurrentPruneAnswer', () => {
  const legacyPrompt = `${HEAD}\nFormat: [{"id": "full-uuid", "reason": "short reason"}]`;

  test('wraps a legacy bare-array answer in the candidates envelope', () => {
    expect(asCurrentPruneAnswer(legacyPrompt, '```json\n[{"id": "a", "reason": "r [x]"}]\n```')).toBe(
      '{"candidates": [{"id": "a", "reason": "r [x]"}]}',
    );
  });

  test('passes answers to the current prompt through unchanged', () => {
    const answer = '[{"id": "a", "reason": "r"}]';
    expect(asCurrentPruneAnswer(`${HEAD}Format: {"candidates": []}`, answer)).toBe(answer);
  });
});

describe('pruneAgreement', () => {
  test('counts votes per memory', () => {
    const a = pruneAgreement([row('a'), row('b'), row('c')], new Set(['a', 'b']), new Set(['b', 'c']));
    expect(a).toMatchObject({ memories: 3, bothArchive: 1, referenceArchive: 2, armArchive: 2 });
    expect(a.votes).toEqual([
      ['archive', 'keep'],
      ['archive', 'archive'],
      ['keep', 'archive'],
    ]);
  });
});
