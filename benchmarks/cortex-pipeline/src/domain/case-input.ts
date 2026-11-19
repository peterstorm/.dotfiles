// A recorded call → what an arm is asked and what its answer is graded against.
//
// The reference is read with cortex's own parser for the transport production
// used (`claude -p`, so the tolerant one). A call whose reference cortex itself
// could not use is not a case: production retried it, and there is nothing to
// agree with. Those calls are counted, because they are the reference model's
// own failure rate.

import type { Extraction } from './extract.ts';
import { type RecordedCall, type Result, assertNever, err, ok } from './model.ts';
import type { AnswerError, CortexJobs } from './port.ts';
import { type PruneRow, asCurrentPruneAnswer, decide, parsePrunePrompt } from './prune.ts';
import { type MemoryPair, type PairLabel, parseRelatePrompt } from './relate.ts';

export type CaseInput = Readonly<
  | { job: 'relate'; pairs: readonly MemoryPair[]; reference: readonly PairLabel[] }
  | { job: 'prune'; rows: readonly PruneRow[]; at: Date; reference: ReadonlySet<string> }
  | { job: 'extract'; prompt: string; reference: Extraction }
>;

export type Ineligible = Readonly<
  | { kind: 'reference-failed' }
  | { kind: 'prompt-unparseable'; detail: string }
  | { kind: 'reference-unusable'; error: AnswerError }
>;

/** Only the readers: parsing and guarding never call a model. */
export type Readers = Readonly<{
  relate: Pick<CortexJobs['relate'], 'read'>;
  prune: Pick<CortexJobs['prune'], 'read' | 'guardOf'>;
  extract: Pick<CortexJobs['extract'], 'read'>;
}>;

/** relate: pairs; prune: memories; extract: prompt characters. */
export const sizeOf = (input: CaseInput): number => {
  switch (input.job) {
    case 'relate':
      return input.pairs.length;
    case 'prune':
      return input.rows.length;
    case 'extract':
      return input.prompt.length;
    default:
      return assertNever(input);
  }
};

export const caseInput = (call: RecordedCall, readers: Readers): Result<CaseInput, Ineligible> => {
  const reference = call.reference;
  if (reference.kind === 'failed') return err({ kind: 'reference-failed' });
  const unusable = (error: AnswerError) => err({ kind: 'reference-unusable', error } as const);
  switch (call.job) {
    case 'relate': {
      const pairs = parseRelatePrompt(call.prompt);
      if (!pairs.ok) return err({ kind: 'prompt-unparseable', detail: pairs.error.detail });
      const labels = readers.relate.read(pairs.value, reference.text, false);
      return labels.ok ? ok({ job: 'relate', pairs: pairs.value, reference: labels.value }) : unusable(labels.error);
    }
    case 'prune': {
      const rows = parsePrunePrompt(call.prompt);
      if (!rows.ok) return err({ kind: 'prompt-unparseable', detail: rows.error.detail });
      const nominated = readers.prune.read(asCurrentPruneAnswer(call.prompt, reference.text));
      if (!nominated.ok) return unusable(nominated.error);
      const decision = decide(rows.value, nominated.value, readers.prune.guardOf, call.at);
      return decision.kind === 'rejected'
        ? unusable({ kind: 'corrupt', reason: `named ids not in the batch: ${decision.unknownIds.slice(0, 3).join(', ')}` })
        : ok({ job: 'prune', rows: rows.value, at: call.at, reference: decision.archived });
    }
    case 'extract': {
      const extraction = readers.extract.read(reference.text);
      return extraction.ok ? ok({ job: 'extract', prompt: call.prompt, reference: extraction.value }) : unusable(extraction.error);
    }
    default:
      return assertNever(call.job);
  }
};
