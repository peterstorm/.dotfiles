import { describe, expect, test } from 'bun:test';
import { crossCheck } from './crosscheck.ts';
import { type Run, SkillId, modelRef } from './model.ts';
import type { Classification, SkillRevision } from './skill-catalog.ts';

const at = (iso: string): Date => new Date(iso);
const run = (file: string, start: string, end: string): Run => ({
  sessionId: file,
  file,
  startedAt: at(start),
  endedAt: at(end),
  prompt: '',
  model: modelRef('desktop-vllm', 'glm'),
  mixedModels: false,
  thinkingLevel: null,
  toolCalls: [],
  evidence: [],
  outcome: { kind: 'all-clear' },
  usage: { input: 0, output: 0, reasoning: 0 },
});
const revision: SkillRevision = { skill: SkillId('x'), commit: 'c', committedAt: at('2026-01-01T00:00:00Z'), promptTemplate: '', timeoutSec: null };
const as = (skill: string): Classification => ({ kind: 'skill', skill: SkillId(skill), revision, hits: 5 });

describe('crossCheck', () => {
  test('skills ending in the same minute are told apart by their start', () => {
    // The 22:00 cortex chain: usefulness runs first, prune starts when it finishes.
    const runs = [
      { run: run('use', '2026-10-20T22:00:00Z', '2026-10-20T22:00:40Z'), classification: as('cortex-usefulness') },
      { run: run('prune', '2026-10-20T22:00:41Z', '2026-10-20T22:01:20Z'), classification: as('cortex-prune') },
    ];
    const log = [
      { at: at('2026-10-20T22:01:21Z'), skill: SkillId('cortex-prune'), status: 'suppressed', durationMs: 40_000 },
      { at: at('2026-10-20T22:00:41Z'), skill: SkillId('cortex-usefulness'), status: 'suppressed', durationMs: 41_000 },
    ];
    expect(crossCheck(runs, log)).toEqual({ joined: 2, agree: 2, disagree: [] });
  });

  test('log lines with no run nearby are not counted', () => {
    const runs = [{ run: run('a', '2026-10-20T08:00:00Z', '2026-10-20T08:01:00Z'), classification: as('tech-digest') }];
    const log = [{ at: at('2026-10-20T12:00:00Z'), skill: SkillId('discount-watch'), status: 'claude_error', durationMs: null }];
    expect(crossCheck(runs, log).joined).toBe(0);
  });
});
