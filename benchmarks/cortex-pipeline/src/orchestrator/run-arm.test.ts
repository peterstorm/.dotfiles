import { describe, expect, test } from 'bun:test';
import { type Job, SessionId, ok } from '../domain/model.ts';
import type { ArmTransport, CortexJobs, Exchange } from '../domain/port.ts';
import { runArm } from './run-arm.ts';

const exchange = (prompt: string, fail: boolean): Exchange => ({
  prompt,
  request: { timeoutMs: 1, maxTokens: null, decoding: 'none' },
  outcome: fail
    ? { kind: 'failed', error: 'boom', latencyMs: 1 }
    : { kind: 'answered', text: '{}', direct: true, meta: { latencyMs: 1, servedModel: null, promptTokens: null, completionTokens: null } },
});

/** Fake jobs that record how many asks are in flight at once. */
const fakeJobs = (state: { inFlight: number; peak: number }): CortexJobs => {
  const ask = (label: string, fail = false) => async () => {
    state.inFlight += 1;
    state.peak = Math.max(state.peak, state.inFlight);
    await Bun.sleep(5);
    state.inFlight -= 1;
    return exchange(label, fail);
  };
  return {
    relate: { ask: ask('relate'), read: () => ok([]) },
    prune: { ask: ask('prune', true), read: () => ok([]), guardOf: () => null },
    extract: { ask: ask('extract'), read: () => ok({ memories: [], entities: 0 }) },
  };
};

const transport: ArmTransport = async () => {
  throw new Error('fake jobs never call the transport');
};

describe('runArm', () => {
  test('asks every case once, saves each exchange, and never exceeds the concurrency', async () => {
    const state = { inFlight: 0, peak: 0 };
    const saved: Array<{ session: string; job: Job; prompt: string }> = [];
    const cases = Array.from({ length: 9 }, (_, i) => ({
      session: SessionId(`s${i}`),
      input:
        i % 3 === 0
          ? ({ job: 'prune', rows: [], at: new Date(), reference: new Set<string>() } as const)
          : ({ job: 'relate', pairs: [], reference: [] } as const),
    }));
    const tally = await runArm(
      cases,
      {
        jobs: fakeJobs(state),
        transport,
        save: async (session, job, ex) => {
          saved.push({ session, job, prompt: ex.prompt });
        },
        progress: () => undefined,
      },
      2,
    );
    expect(tally).toEqual({ asked: 9, answered: 6, failed: 3 });
    expect(new Set(saved.map((s) => s.session)).size).toBe(9);
    expect(saved.every((s) => s.prompt === s.job)).toBe(true);
    expect(state.peak).toBe(2);
  });
});
