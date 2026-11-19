// Shared vocabulary of the cortex pipeline benchmark.
//
// A *recorded call* is one background LLM call cortex made in production (a
// `claude -p` session): the prompt it sent and the answer it got, which is the
// reference. A *case* is a recorded call selected into a protocol. An *arm* is a
// model and the transport cortex would use to reach it. A *response* is what an
// arm answered for a case.

export type Result<T, E> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: E };

export const ok = <T>(value: T): Result<T, never> => ({ ok: true, value });
export const err = <E>(error: E): Result<never, E> => ({ ok: false, error });

export const assertNever = (x: never): never => {
  throw new Error(`unreachable: ${JSON.stringify(x)}`);
};

/** The three background jobs cortex sends to an LLM. */
export const JOBS = ['relate', 'prune', 'extract'] as const;
export type Job = (typeof JOBS)[number];

export const isJob = (s: string): s is Job => (JOBS as readonly string[]).includes(s);

/** A Claude Code session id: the recorded call's identity, and its case id. */
export type SessionId = string & { readonly __brand: 'SessionId' };
export const SessionId = (s: string): SessionId => s as SessionId;

/** What production got back for a recorded call. `failed` covers API errors Claude Code recorded as `<synthetic>`. */
export type Reference =
  | Readonly<{ kind: 'answered'; model: string; text: string }>
  | Readonly<{ kind: 'failed'; detail: string }>;

export type RecordedCall = Readonly<{
  session: SessionId;
  job: Job;
  at: Date;
  prompt: string;
  reference: Reference;
}>;

// Cortex's vocabularies, mirrored so the core stays free of cortex imports. The
// cortex adapter's contract test fails if either list drifts from cortex's own.
export const EDGE_RELATIONS = [
  'relates_to',
  'derived_from',
  'contradicts',
  'exemplifies',
  'refines',
  'supersedes',
  'source_of',
] as const;
export type EdgeRelation = (typeof EDGE_RELATIONS)[number];

export const MEMORY_TYPES = [
  'architecture',
  'decision',
  'pattern',
  'gotcha',
  'context',
  'progress',
  'code_description',
  'code',
] as const;
export type MemoryType = (typeof MEMORY_TYPES)[number];

export const isMemoryType = (s: string): s is MemoryType => (MEMORY_TYPES as readonly string[]).includes(s);
export const isEdgeRelation = (s: string): s is EdgeRelation => (EDGE_RELATIONS as readonly string[]).includes(s);
