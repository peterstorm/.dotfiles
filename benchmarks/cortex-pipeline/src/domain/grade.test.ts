import { describe, expect, test } from 'bun:test';
import { repeatedPairLabels } from './consistency.ts';
import { gradeExtract, gradePrune, gradeRelate } from './grade.ts';
import { SessionId, err, ok } from './model.ts';
import type { CallMeta, Exchange } from './port.ts';
import type { PruneRow } from './prune.ts';
import type { MemoryPair, PairLabel } from './relate.ts';
import { renderReport } from './report.ts';
import { summariseArm } from './summary.ts';

const META: CallMeta = { latencyMs: 1200, servedModel: 'm', promptTokens: 100, completionTokens: 40 };
const answered = (text: string): Pick<Exchange, 'outcome'> => ({ outcome: { kind: 'answered', text, direct: true, meta: META } });
const failed = (error: string): Pick<Exchange, 'outcome'> => ({ outcome: { kind: 'failed', error, latencyMs: 90_000 } });

const none: PairLabel = { kind: 'none' };
const refines: PairLabel = { kind: 'edge', relation: 'refines', strength: 0.8 };
const S = SessionId('s1');

describe('grading', () => {
  test('relate: a usable answer is compared pair by pair', () => {
    const g = gradeRelate(S, [none, refines], answered('x'), () => ok([refines, refines]));
    expect(g).toEqual({
      job: 'relate',
      session: S,
      graded: { kind: 'usable', value: [{ reference: none, arm: refines }, { reference: refines, arm: refines }], meta: META },
    });
  });

  test('a transport failure is classified, an unreadable answer is unparseable — neither is a decline', () => {
    expect(gradeRelate(S, [none], failed('LLM request timed out after 90000ms'), () => ok([none])).graded).toMatchObject({
      kind: 'failed',
      failure: 'timeout',
      latencyMs: 90_000,
    });
    expect(gradeRelate(S, [none], answered('garbage'), () => err({ kind: 'unparseable', reason: 'no JSON' })).graded).toMatchObject({
      kind: 'failed',
      failure: 'unparseable',
      latencyMs: 1200,
    });
  });

  test('prune: naming an id outside the batch fails the batch as corrupt', () => {
    const rows: PruneRow[] = [{ id: 'a', memory_type: 'context', confidence: 0.5, access_count: 0, pinned: false, created_day: '2026-10-01', summary: 'a' }];
    const g = gradePrune(S, rows, new Set(), new Date(), answered('x'), () => ok(['ghost']), () => null);
    expect(g.graded).toMatchObject({ kind: 'failed', failure: 'corrupt' });
  });

  test('extract: usable answers are soft-matched against the reference', () => {
    const memory = { summary: 'garmin sync writes the fitness note', content: 'daily', memory_type: 'progress', scope: 'project' };
    const g = gradeExtract(S, { memories: [memory], entities: 0 }, answered('x'), () => ok({ memories: [memory], entities: 2 }));
    expect(g.graded).toMatchObject({ kind: 'usable', value: { matched: 1, sameType: 1 } });
  });
});

describe('summary and report', () => {
  test('summarises an arm and renders every section', () => {
    const grades = [
      gradeRelate(SessionId('a'), [none, refines], answered('x'), () => ok([none, refines])),
      gradeRelate(SessionId('b'), [refines], failed('LLM API returned empty content'), () => ok([none])),
    ];
    const summary = summariseArm(grades);
    expect(summary.prune).toBeNull();
    expect(summary.relate).toMatchObject({ pairs: 2, exact: 2, reliability: { cases: 2, usable: 1 } });
    expect(summary.relate?.reliability.failures.get('empty')).toBe(1);

    const health = { calls: 1, referenceFailed: 0, promptUnparseable: 0, referenceUnusable: 0, eligible: 1, referenceModels: new Map([['m', 1]]) };
    const md = renderReport({
      protocolId: 'v1-test',
      cases: { relate: 2, prune: 0, extract: 0 },
      health: { relate: health, prune: health, extract: health },
      referenceSelfAgreement: [{ reference: none, arm: none }, { reference: refines, arm: refines }],
      arms: [{ arm: 'direct:p/m', summary, cortexCommits: ['abc'], servedModels: ['m'] }],
      generatedAt: new Date('2026-11-19T00:00:00Z'),
    });
    for (const heading of ['## Corpus and reference health', '## The reference against itself', '## Relate', '## Prune', '## Extract', '## Proposed gate']) {
      expect(md).toContain(heading);
    }
    expect(md).toContain('| direct:p/m | 1/2 | empty 1 |');
  });
});

describe('repeatedPairLabels', () => {
  const pair = (s: string, t: string): MemoryPair => ({
    source: { id: s, memory_type: 'context', summary: '', content: '' },
    target: { id: t, memory_type: 'context', summary: '', content: '' },
  });

  test('pairs the first two labels of a pair from different sessions, in time order, once per pair', () => {
    const batches = [
      { session: SessionId('late'), at: new Date('2026-11-03'), pairs: [pair('a', 'b')], labels: [refines] },
      { session: SessionId('early'), at: new Date('2026-11-01'), pairs: [pair('a', 'b'), pair('c', 'd')], labels: [none, none] },
      { session: SessionId('later'), at: new Date('2026-11-05'), pairs: [pair('a', 'b')], labels: [none] },
    ];
    expect(repeatedPairLabels(batches)).toEqual([{ reference: none, arm: refines }]);
  });

  test('ignores a pair repeated inside one session', () => {
    const batches = [{ session: SessionId('one'), at: new Date(), pairs: [pair('a', 'b'), pair('a', 'b')], labels: [none, refines] }];
    expect(repeatedPairLabels(batches)).toEqual([]);
  });
});
