import { describe, expect, test } from 'bun:test';
import { type SkillContract, type Verdict, grade, isHardFailure, tomorrowIsWeekday } from './checks.ts';
import { type Run, type RunOutcome, type ToolCall, SkillId, modelRef } from './model.ts';
import type { SkillRevision } from './skill-catalog.ts';

const revision = (promptTemplate = 'template', timeoutSec: number | null = 600): SkillRevision => ({
  skill: SkillId('s'),
  commit: 'c',
  committedAt: new Date('2026-09-01T00:00:00Z'),
  promptTemplate,
  timeoutSec,
});

const run = (outcome: RunOutcome, toolCalls: readonly ToolCall[] = [], over: Partial<Run> = {}): Run => ({
  sessionId: 's',
  file: '/f.jsonl',
  startedAt: new Date('2026-10-01T19:00:00Z'),
  endedAt: new Date('2026-10-01T19:05:00Z'),
  prompt: '',
  model: modelRef('desktop-vllm', 'glm'),
  mixedModels: false,
  thinkingLevel: 'low',
  toolCalls,
  evidence: [],
  outcome,
  usage: { input: 0, output: 0, reasoning: 0 },
  ...over,
});

const delivered = (text: string): RunOutcome => ({ kind: 'delivered', text, truncated: false });
const verdict = (vs: readonly Verdict[], check: string): Verdict | undefined => vs.find((v) => v.check === check);

const contract = (over: Partial<SkillContract> = {}): SkillContract => ({
  skill: SkillId('s'),
  allClear: 'allowed',
  numberScales: [1],
  requirements: [],
  ...over,
});

describe('universal checks', () => {
  test('a failed run is a reliability fact and gets no quality verdicts', () => {
    expect(grade(run({ kind: 'failed', reason: { kind: 'no-text' } }), revision(), undefined)).toEqual([]);
  });

  test('sentinel: decorated or accompanied ALL_CLEAR fails, a prose mention passes', () => {
    for (const text of ['`ALL_CLEAR`', 'No late activity.\n\nALL_CLEAR', '**ALL_CLEAR**\n\nCoverage: 20 listings']) {
      expect(verdict(grade(run(delivered(text)), revision(), undefined), 'sentinel-exact')?.status).toBe('fail');
    }
    const prose = 'credential health was ALL_CLEAR, the backfill ran';
    expect(verdict(grade(run(delivered(prose)), revision(), undefined), 'sentinel-exact')?.status).toBe('pass');
  });

  test('leaked reasoning markup fails', () => {
    const v = verdict(grade(run(delivered('<think>hmm</think> Report')), revision(), undefined), 'no-leaked-markup');
    expect(v?.status).toBe('fail');
  });

  test('timeout is n/a without a configured timeout and fails past it', () => {
    expect(verdict(grade(run(delivered('x')), revision('t', null), undefined), 'within-timeout')?.status).toBe('n/a');
    expect(verdict(grade(run(delivered('x')), revision('t', 60), undefined), 'within-timeout')?.status).toBe('fail');
  });

  test('ungrounded figures are a heuristic flag, never a hard failure', () => {
    const vs = grade(run(delivered('Prices: 111, 222, 333, 444, 555')), revision(), undefined);
    const v = verdict(vs, 'numbers-grounded');
    expect(v?.status).toBe('fail');
    expect(v !== undefined && isHardFailure(v)).toBe(false);
  });
});

describe('contract checks', () => {
  test('ALL_CLEAR from a skill with no nothing-to-report condition fails', () => {
    const vs = grade(run({ kind: 'all-clear' }), revision(), contract({ allClear: 'forbidden' }));
    expect(verdict(vs, 'all-clear-allowed')?.status).toBe('fail');
  });

  test('a requirement binds only when the prompt that ran contains its clause', () => {
    const c = contract({
      requirements: [{ label: 'w', kind: 'command', pattern: /commute-weather\.ts/, when: [{ kind: 'prompt-says', text: 'commute-weather.ts' }] }],
    });
    expect(verdict(grade(run(delivered('x')), revision('old prompt'), c), 'command:w')?.status).toBe('n/a');
    expect(verdict(grade(run(delivered('x')), revision('run commute-weather.ts'), c), 'command:w')?.status).toBe('fail');
    const called = run(delivered('x'), [{ kind: 'bash', command: 'bun commute-weather.ts 55 12 tz 1' }]);
    expect(verdict(grade(called, revision('run commute-weather.ts'), c), 'command:w')?.status).toBe('pass');
  });

  test('tomorrow-is-weekday follows Copenhagen days', () => {
    expect(tomorrowIsWeekday(new Date('2026-10-02T19:00:00Z'))).toBe(false); // Friday evening
    expect(tomorrowIsWeekday(new Date('2026-10-04T19:00:00Z'))).toBe(true); // Sunday evening
  });

  test('vault-write: a cd-relative heredoc counts; a no-op ALL_CLEAR that read the note counts only when allowed', () => {
    const path = /remotevault\/personal\/fitness\/\d{4}\/\d{2}\/\d{4}-\d{2}-\d{2}\.md/;
    const c = (noOp: 'read-counts' | 'must-write') =>
      contract({ requirements: [{ label: 'note', kind: 'vault-write', path, noOp }] });
    const wrote = run({ kind: 'all-clear' }, [
      { kind: 'bash', command: "cd ~/dev/notes/remotevault/personal/fitness; cat > 2026/10/2026-10-23.md <<'E'\n---\nE" },
    ]);
    expect(verdict(grade(wrote, revision(), c('must-write')), 'vault-write:note')?.status).toBe('pass');
    const readOnly = run({ kind: 'all-clear' }, [
      { kind: 'bash', command: 'cat ~/dev/notes/remotevault/personal/fitness/2026/10/2026-10-23.md' },
    ]);
    expect(verdict(grade(readOnly, revision(), c('read-counts')), 'vault-write:note')?.status).toBe('pass');
    expect(verdict(grade(readOnly, revision(), c('must-write')), 'vault-write:note')?.status).toBe('fail');
    // A decorated no-op is the sentinel's failure alone, not also a missing write.
    const decorated = { ...readOnly, outcome: delivered('Note already complete.\n\nALL_CLEAR') };
    const vs = grade(decorated, revision(), c('read-counts'));
    expect(verdict(vs, 'vault-write:note')?.status).toBe('pass');
    expect(verdict(vs, 'sentinel-exact')?.status).toBe('fail');
    // A delivered report that never signalled all-clear still owes the write.
    const report = { ...readOnly, outcome: delivered('Sleep 81, HRV 44') };
    expect(verdict(grade(report, revision(), c('read-counts')), 'vault-write:note')?.status).toBe('fail');
  });

  test('output-matches counts every occurrence; max-lines ignores blank lines', () => {
    const c = contract({
      requirements: [
        { label: 'links', kind: 'output-matches', pattern: /\[[^\]]+\]\(https?:\/\/[^)]+\)/, min: 2 },
        { label: 'short', kind: 'max-lines', max: 2 },
      ],
    });
    const vs = grade(run(delivered('[a](https://a.io)\n\n[b](https://b.io)')), revision(), c);
    expect(verdict(vs, 'output-matches:links')?.status).toBe('pass');
    expect(verdict(vs, 'max-lines:short')?.status).toBe('pass');
    expect(verdict(grade(run({ kind: 'all-clear' }), revision(), c), 'output-matches:links')?.status).toBe('n/a');
  });
});
