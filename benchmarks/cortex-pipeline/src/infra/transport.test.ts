// The direct arm end to end over HTTP: cortex's real chatCompletion against a
// minimal OpenAI-compatible server, so the wire request a local model would get
// is asserted, not assumed.

import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { z } from 'zod';
import { DEFAULTS } from '../cli-args.ts';
import { parseArm } from '../domain/arm.ts';
import type { MemoryPair } from '../domain/relate.ts';
import { type CortexModule, cortexJobs, loadCortex } from './cortex.ts';
import { armTransport } from './transport.ts';

const ROOT = process.env.CORTEX_ROOT ?? DEFAULTS.cortex;

const bodies: Record<string, unknown>[] = [];
let server: ReturnType<typeof Bun.serve>;
let cortex: CortexModule;

const ENV = ['CORTEX_LLM_API_URL', 'CORTEX_LLM_API_KEY', 'CORTEX_LLM_MODEL', 'CORTEX_LLM_PROVIDER'] as const;
const saved = new Map(ENV.map((k) => [k, process.env[k]]));

beforeAll(async () => {
  server = Bun.serve({
    port: 0,
    fetch: async (req) => {
      const url = new URL(req.url);
      if (url.pathname.endsWith('/models')) return Response.json({ data: [{ id: 'served-model' }] });
      const raw: unknown = await req.json();
      bodies.push(z.record(z.string(), z.unknown()).parse(raw));
      return Response.json({
        model: 'served-model',
        choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: '{"edges": []}' } }],
        usage: { prompt_tokens: 321, completion_tokens: 7 },
      });
    },
  });
  process.env.CORTEX_LLM_API_URL = `http://127.0.0.1:${server.port}/v1`;
  process.env.CORTEX_LLM_API_KEY = 'test-key';
  process.env.CORTEX_LLM_MODEL = 'configured-model';
  const loaded = await loadCortex(ROOT);
  if (!loaded.ok) throw new Error(`cortex at ${ROOT} lacks ${loaded.error.names.join(', ')}; set CORTEX_ROOT`);
  cortex = loaded.value;
});

afterAll(() => {
  server.stop(true);
  for (const [k, v] of saved) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
});

const pairs: MemoryPair[] = [
  {
    source: { id: 'a', memory_type: 'context', summary: 's', content: 'c' },
    target: { id: 'b', memory_type: 'pattern', summary: 't', content: 'd' },
  },
];

const transportFor = (spec: string) => {
  const arm = parseArm(spec);
  if (!arm.ok) throw new Error(spec);
  const t = armTransport(arm.value, cortex);
  if (!t.ok) throw new Error('no endpoint');
  return t.value;
};

describe('direct arm', () => {
  test("sends the job's schema with thinking disabled to the arm's model, and records what the server reports", async () => {
    bodies.length = 0;
    const ex = await cortexJobs(cortex).relate.ask(pairs, transportFor('direct:local/arm-model'));
    expect(ex.outcome).toEqual({
      kind: 'answered',
      text: '{"edges": []}',
      direct: true,
      meta: { latencyMs: expect.any(Number), servedModel: 'served-model', promptTokens: 321, completionTokens: 7 },
    });
    const body = bodies[0];
    expect(body).toMatchObject({
      model: 'arm-model',
      max_tokens: 4096,
      temperature: 0,
      stream: false,
      chat_template_kwargs: { thinking: false, enable_thinking: false },
      response_format: { type: 'json_schema' },
    });
  });

  test('unguided drops the schema but keeps the answer budget', async () => {
    bodies.length = 0;
    await cortexJobs(cortex).relate.ask(pairs, transportFor('direct:local/arm-model+unguided'));
    expect(bodies[0]?.response_format).toBeUndefined();
    expect(bodies[0]?.max_tokens).toBe(4096);
  });
});
