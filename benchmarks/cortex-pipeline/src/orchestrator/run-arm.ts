// Ask one arm every case of a protocol it has not answered yet.
//
// Each case is one production request through cortex's job function. Cases run
// `concurrency` at a time (cortex's own default is 2: background work is a
// polite straggler on a shared server, so latency is measured under the load
// production puts on it). Every exchange is saved as soon as it returns, so an
// interrupted run resumes without asking a case twice.

import type { CaseInput } from '../domain/case-input.ts';
import { type Job, type SessionId, assertNever } from '../domain/model.ts';
import type { ArmTransport, CortexJobs, Exchange } from '../domain/port.ts';

export type RunCase = Readonly<{ session: SessionId; input: CaseInput }>;

export type RunPorts = Readonly<{
  jobs: CortexJobs;
  transport: ArmTransport;
  save: (session: SessionId, job: Job, exchange: Exchange) => Promise<void>;
  progress: (line: string) => void;
}>;

export type RunTally = Readonly<{ asked: number; answered: number; failed: number }>;

const ask = (input: CaseInput, jobs: CortexJobs, transport: ArmTransport): Promise<Exchange> => {
  switch (input.job) {
    case 'relate':
      return jobs.relate.ask(input.pairs, transport);
    case 'prune':
      return jobs.prune.ask(input.rows, transport);
    case 'extract':
      return jobs.extract.ask(input.prompt, transport);
    default:
      return assertNever(input);
  }
};

export const runArm = async (
  pending: readonly RunCase[],
  ports: RunPorts,
  concurrency: number,
): Promise<RunTally> => {
  let next = 0;
  let answered = 0;
  let failed = 0;
  const worker = async (): Promise<void> => {
    for (let i = next++; i < pending.length; i = next++) {
      const c = pending[i];
      if (c === undefined) continue;
      const exchange = await ask(c.input, ports.jobs, ports.transport);
      await ports.save(c.session, c.input.job, exchange);
      const o = exchange.outcome;
      if (o.kind === 'answered') answered += 1;
      else failed += 1;
      ports.progress(
        `[${answered + failed}/${pending.length}] ${c.input.job} ${c.session.slice(0, 8)} ` +
          (o.kind === 'answered' ? `answered in ${o.meta.latencyMs} ms` : `failed: ${o.error.slice(0, 120)}`),
      );
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, concurrency) }, worker));
  return { asked: answered + failed, answered, failed };
};
