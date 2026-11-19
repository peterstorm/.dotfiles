// Grading: one arm's exchange for one case, against the case's reference.
//
// Usable answers are compared to the reference; anything else is a failure with
// a class. A failure is never a decline: production retries a failed batch, so
// an arm that fails often costs retries and latency, and an arm that "declines"
// by returning garbage would be scored as a failure here, not as agreement on
// "no edge".

import { type Extraction, type ExtractionMatch, matchExtractions } from './extract.ts';
import { type FailureClass, classifyTransportError } from './failure.ts';
import type { CaseInput, Readers } from './case-input.ts';
import { type SessionId, assertNever } from './model.ts';
import type { AnswerError, CallMeta, Exchange } from './port.ts';
import { type GuardOf, type PruneAgreement, type PruneRow, decide, pruneAgreement } from './prune.ts';
import { type LabelPair, type PairLabel, zipLabels } from './relate.ts';
import type { Result } from './model.ts';

export type Graded<T> =
  | Readonly<{ kind: 'usable'; value: T; meta: CallMeta }>
  | Readonly<{ kind: 'failed'; failure: FailureClass; detail: string; latencyMs: number | null }>;

export type CaseGrade = Readonly<
  | { job: 'relate'; session: SessionId; graded: Graded<readonly LabelPair[]> }
  | { job: 'prune'; session: SessionId; graded: Graded<PruneAgreement & { nominatedGuarded: number }> }
  | { job: 'extract'; session: SessionId; graded: Graded<ExtractionMatch> }
>;

/** What grading reads of an exchange: its outcome. Stored responses keep the prompt's hash, not the prompt. */
type Answered = Pick<Exchange, 'outcome'>;

const answerFailure =(e: AnswerError, meta: CallMeta): Graded<never> => ({
  kind: 'failed',
  failure: e.kind,
  detail: e.reason,
  latencyMs: meta.latencyMs,
});

/**
 * Grade one exchange: a transport failure is classified from its message; an
 * answer is read with cortex's parser (`read`) and, if usable, compared.
 */
const gradeExchange = <A, T>(
  exchange: Answered,
  read: (text: string, direct: boolean) => Result<A, AnswerError>,
  compare: (answer: A) => Result<T, AnswerError>,
): Graded<T> => {
  const o = exchange.outcome;
  if (o.kind === 'failed') {
    return { kind: 'failed', failure: classifyTransportError(o.error), detail: o.error.slice(0, 300), latencyMs: o.latencyMs };
  }
  const answer = read(o.text, o.direct);
  if (!answer.ok) return answerFailure(answer.error, o.meta);
  const compared = compare(answer.value);
  return compared.ok ? { kind: 'usable', value: compared.value, meta: o.meta } : answerFailure(compared.error, o.meta);
};

export const gradeRelate = (
  session: SessionId,
  reference: readonly PairLabel[],
  exchange: Answered,
  read: (text: string, direct: boolean) => Result<readonly PairLabel[], AnswerError>,
): CaseGrade => ({
  job: 'relate',
  session,
  graded: gradeExchange(exchange, read, (labels) => ({ ok: true, value: zipLabels(reference, labels) })),
});

export const gradePrune = (
  session: SessionId,
  rows: readonly PruneRow[],
  reference: ReadonlySet<string>,
  at: Date,
  exchange: Answered,
  read: (text: string) => Result<readonly string[], AnswerError>,
  guardOf: GuardOf,
): CaseGrade => ({
  job: 'prune',
  session,
  graded: gradeExchange(exchange, (text) => read(text), (nominated) => {
    const decision = decide(rows, nominated, guardOf, at);
    return decision.kind === 'rejected'
      ? { ok: false, error: { kind: 'corrupt', reason: `named ids not in the batch: ${decision.unknownIds.slice(0, 3).join(', ')}` } }
      : { ok: true, value: { ...pruneAgreement(rows, reference, decision.archived), nominatedGuarded: decision.nominatedGuarded } };
  }),
});

/** Grade an arm's exchange for a case, with the case's own job grader. */
export const gradeCase = (session: SessionId, input: CaseInput, exchange: Answered, readers: Readers): CaseGrade => {
  switch (input.job) {
    case 'relate':
      return gradeRelate(session, input.reference, exchange, (text, direct) => readers.relate.read(input.pairs, text, direct));
    case 'prune':
      return gradePrune(session, input.rows, input.reference, input.at, exchange, readers.prune.read, readers.prune.guardOf);
    case 'extract':
      return gradeExtract(session, input.reference, exchange, readers.extract.read);
    default:
      return assertNever(input);
  }
};

export const gradeExtract = (
  session: SessionId,
  reference: Extraction,
  exchange: Answered,
  read: (text: string) => Result<Extraction, AnswerError>,
): CaseGrade => ({
  job: 'extract',
  session,
  graded: gradeExchange(exchange, (text) => read(text), (extraction) => ({ ok: true, value: matchExtractions(reference, extraction) })),
});
