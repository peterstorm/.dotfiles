// Contract with a real cortex checkout: CORTEX_ROOT, else the deployed plugin.
// Pins what the adapter assumes about cortex: the prompts round-trip through the
// benchmark's parsers, each job sends production's request, and the readers
// apply production's parse and join.

import { beforeAll, describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { DEFAULTS } from '../cli-args.ts';
import { MEMORY_TYPES } from '../domain/model.ts';
import type { ArmTransport, CortexJobs } from '../domain/port.ts';
import { type PruneRow, parsePrunePrompt } from '../domain/prune.ts';
import { type MemoryPair, parseRelatePrompt } from '../domain/relate.ts';
import { type CortexModule, cortexJobs, cortexPrompts, loadCortex, vocabularyDrift } from './cortex.ts';

const ROOT = process.env.CORTEX_ROOT ?? DEFAULTS.cortex;

let cortex: CortexModule;
let jobs: CortexJobs;

beforeAll(async () => {
  const loaded = await loadCortex(ROOT);
  if (!loaded.ok) throw new Error(`cortex at ${ROOT} lacks ${loaded.error.names.join(', ')}; set CORTEX_ROOT`);
  cortex = loaded.value;
  jobs = cortexJobs(cortex);
});

const text = (alphabet: readonly string[], max: number) =>
  fc.array(fc.constantFrom(...alphabet), { maxLength: max }).map((cs) => cs.join(''));

// Free text without the template's own markers ("\nPair ", "  Target [", "\n    Content: ").
const prose = text(['a', 'b', 'z', ' ', '.', ',', ':', '-', '\n', '[', ']', '|', '0', '9'], 60);
const id = text(['a', 'f', '0', '9', '-'], 12).filter((s) => s.length > 0);
const memoryArb = fc.record({
  id,
  memory_type: fc.constantFrom(...MEMORY_TYPES),
  summary: prose.filter((s) => !s.includes('\n')),
  content: prose,
});
const pairsArb: fc.Arbitrary<MemoryPair[]> = fc.array(fc.record({ source: memoryArb, target: memoryArb }), { minLength: 1, maxLength: 12 });

const rowArb: fc.Arbitrary<PruneRow> = fc.record({
  id: id.map((s) => `extraction-${s}`),
  memory_type: fc.constantFrom(...MEMORY_TYPES),
  confidence: fc.integer({ min: 0, max: 100 }).map((k) => k / 100),
  access_count: fc.nat(500),
  pinned: fc.boolean(),
  created_day: fc.date({ min: new Date('2026-01-01'), max: new Date('2026-12-31'), noInvalidDate: true }).map((d) => d.toISOString().slice(0, 10)),
  summary: text(['a', 'b', ' ', '.', '|', '-', '\n'], 140).filter((s) => s.trim().length > 0 && !s.startsWith('\n')),
});

const recording = (reply: string, seen: { prompt?: string } = {}): ArmTransport => async (prompt) => {
  seen.prompt = prompt;
  return { text: reply, direct: true, meta: { latencyMs: 1, servedModel: 'fake', promptTokens: null, completionTokens: null } };
};

describe('cortex vocabulary', () => {
  test("matches the benchmark's mirror", () => {
    expect(vocabularyDrift(cortex)).toEqual([]);
  });
});

describe('prompt round trips', () => {
  test("relate: the benchmark's parser recovers every pair from cortex's prompt", () => {
    fc.assert(
      fc.property(pairsArb, (pairs) => {
        expect(parseRelatePrompt(cortexPrompts(cortex).relate(pairs))).toEqual({ ok: true, value: pairs });
      }),
    );
  });

  test("prune: the benchmark's parser recovers every row from cortex's prompt", () => {
    fc.assert(
      fc.property(fc.array(rowArb, { minLength: 1, maxLength: 20 }), (rows) => {
        expect(parsePrunePrompt(cortexPrompts(cortex).prune(rows))).toEqual({ ok: true, value: rows });
      }),
    );
  });
});

describe("each job sends production's request", () => {
  const pairs: MemoryPair[] = [
    {
      source: { id: 'a', memory_type: 'context', summary: 's', content: 'c' },
      target: { id: 'b', memory_type: 'pattern', summary: 't', content: 'd' },
    },
  ];

  test('relate: strict schema, 4096-token answer, 90 s, the prompt cortex builds', async () => {
    const seen: { prompt?: string } = {};
    const ex = await jobs.relate.ask(pairs, recording('{"edges": []}', seen));
    expect(ex.request).toEqual({ timeoutMs: 90_000, maxTokens: 4096, decoding: 'json-schema' });
    expect(ex.prompt).toBe(cortexPrompts(cortex).relate(pairs));
    expect(seen.prompt).toBe(ex.prompt);
    expect(ex.outcome).toMatchObject({ kind: 'answered', text: '{"edges": []}', direct: true });
  });

  test('prune: strict candidates schema, cortex prune timeout', async () => {
    const rows: PruneRow[] = [{ id: 'x', memory_type: 'context', confidence: 0.5, access_count: 0, pinned: false, created_day: '2026-10-01', summary: 's' }];
    const ex = await jobs.prune.ask(rows, recording('{"candidates": []}'));
    expect(ex.request.decoding).toBe('json-schema');
    expect(ex.request.timeoutMs).toBeGreaterThan(0);
    expect(ex.prompt).toBe(cortexPrompts(cortex).prune(rows));
  });

  test('extract: JSON mode, 8192-token answer, 90 s, the prompt as given', async () => {
    const ex = await jobs.extract.ask('Extract memories from this Claude Code session transcript.\n…', recording('{"memories": []}'));
    expect(ex.request).toEqual({ timeoutMs: 90_000, maxTokens: 8192, decoding: 'json-object' });
  });

  test('a transport failure is captured, not thrown', async () => {
    const failing: ArmTransport = async () => {
      throw new Error('LLM request timed out after 90000ms');
    };
    const ex = await jobs.relate.ask(pairs, failing);
    expect(ex.outcome).toMatchObject({ kind: 'failed', error: 'LLM request timed out after 90000ms' });
  });

  test('a reply cortex rejects is still captured for grading', async () => {
    const ex = await jobs.relate.ask(pairs, recording('not json'));
    expect(ex.outcome).toMatchObject({ kind: 'answered', text: 'not json' });
  });
});

describe('readers apply production parse and join', () => {
  const pairs: MemoryPair[] = [
    { source: { id: 'a', memory_type: 'context', summary: '', content: '' }, target: { id: 'b', memory_type: 'context', summary: '', content: '' } },
    { source: { id: 'c', memory_type: 'context', summary: '', content: '' }, target: { id: 'd', memory_type: 'context', summary: '', content: '' } },
  ];

  test('relate, direct: strict parse, join by pair_index', () => {
    const answer = JSON.stringify({ edges: [{ pair_index: 2, source_id: 'c', target_id: 'd', relation_type: 'refines', strength: 0.7 }] });
    expect(jobs.relate.read(pairs, answer, true)).toEqual({
      ok: true,
      value: [{ kind: 'none' }, { kind: 'edge', relation: 'refines', strength: 0.7 }],
    });
    expect(jobs.relate.read(pairs, '```json\n' + answer + '\n```', true)).toMatchObject({ ok: false, error: { kind: 'unparseable' } });
  });

  test('relate, subprocess: tolerant parse of a fenced legacy array, join by ids; an unknown pair is corrupt', () => {
    const legacy = '```json\n[{"source_id": "a", "target_id": "b", "relation_type": "relates_to", "strength": 0.4}]\n```\nSummary…';
    expect(jobs.relate.read(pairs, legacy, false)).toEqual({
      ok: true,
      value: [{ kind: 'edge', relation: 'relates_to', strength: 0.4 }, { kind: 'none' }],
    });
    const flipped = '[{"source_id": "b", "target_id": "a", "relation_type": "relates_to", "strength": 0.4}]';
    expect(jobs.relate.read(pairs, flipped, false)).toMatchObject({ ok: false, error: { kind: 'corrupt' } });
  });

  test('prune and extract read their envelopes', () => {
    expect(jobs.prune.read('{"candidates": [{"id": "x", "reason": "stale"}]}')).toEqual({ ok: true, value: ['x'] });
    expect(jobs.prune.read('[]').ok).toBe(false);
    expect(jobs.extract.read('{"memories": [], "entities": []}')).toEqual({ ok: true, value: { memories: [], entities: 0 } });
    expect(jobs.extract.read('{"memories": [], "entities": [{"entity_name": "x", "entity_type": "service", "predicate": "p", "object": "o"}]}').ok).toBe(false);
  });

  test("guards are cortex's", () => {
    const base: PruneRow = { id: 'x', memory_type: 'context', confidence: 0.5, access_count: 0, pinned: false, created_day: '2026-10-01', summary: '' };
    const now = new Date('2026-11-01T00:00:00Z');
    expect(jobs.prune.guardOf(base, now)).toBeNull();
    expect(jobs.prune.guardOf({ ...base, pinned: true }, now)).toBe('pinned');
    expect(jobs.prune.guardOf({ ...base, memory_type: 'decision', confidence: 0.9 }, now)).toBe('stable');
    expect(jobs.prune.guardOf({ ...base, created_day: '2026-10-31' }, now)).toBe('too-young');
  });
});
