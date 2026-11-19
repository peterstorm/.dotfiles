// The two seams the benchmark crosses: cortex itself (prompt builders, request
// specs, response parsers, guards) and the model behind an arm.
//
// Cortex is reached through its own LlmPromptTransport seam, so an arm is asked
// exactly what production asks: the job decides prompt, schema, answer budget
// and timeout; the arm only decides where the request goes.

import type { Extraction } from './extract.ts';
import type { Result } from './model.ts';
import type { GuardOf, PruneRow } from './prune.ts';
import type { MemoryPair, PairLabel } from './relate.ts';

/** The request options a cortex job hands its transport (cortex's DirectLlmOptions). */
export type RequestOptions = Readonly<{ jsonMode?: boolean; jsonSchema?: object; maxTokens?: number }>;

/** What an arm learned about one call besides the text. Null fields: the transport could not see them. */
export type CallMeta = Readonly<{
  latencyMs: number;
  servedModel: string | null;
  promptTokens: number | null;
  completionTokens: number | null;
}>;

export type TransportReply = Readonly<{ text: string; direct: boolean; meta: CallMeta }>;

/** An arm's transport: cortex's LlmPromptTransport, plus call metadata. Throws on transport failure, as cortex's does. */
export type ArmTransport = (prompt: string, timeoutMs: number, options?: RequestOptions) => Promise<TransportReply>;

/** How a job asked: enough to show the run used production's request, without the schema body. */
export type RequestSpec = Readonly<{
  timeoutMs: number;
  maxTokens: number | null;
  decoding: 'json-schema' | 'json-object' | 'none';
}>;

/** One request and what came back. `failed`: the transport threw (HTTP, timeout, truncation, empty content…). */
export type Exchange = Readonly<{
  prompt: string;
  request: RequestSpec;
  outcome:
    | Readonly<{ kind: 'answered'; text: string; direct: boolean; meta: CallMeta }>
    | Readonly<{ kind: 'failed'; error: string; latencyMs: number }>;
}>;

/** Why an answer that arrived could not be used; production treats each as a failed batch. */
export type AnswerError = Readonly<{ kind: 'unparseable' | 'corrupt'; reason: string }>;

/**
 * Cortex's background jobs, as the benchmark needs them. `ask` sends one request
 * through the job's own production function; `read` parses an answer with the
 * job's own production parser. `direct` selects cortex's strict parser (guided
 * decoding) or its tolerant one (subprocess output), as production does.
 */
export type CortexJobs = Readonly<{
  relate: Readonly<{
    ask: (pairs: readonly MemoryPair[], transport: ArmTransport) => Promise<Exchange>;
    read: (pairs: readonly MemoryPair[], text: string, direct: boolean) => Result<readonly PairLabel[], AnswerError>;
  }>;
  prune: Readonly<{
    ask: (rows: readonly PruneRow[], transport: ArmTransport) => Promise<Exchange>;
    read: (text: string) => Result<readonly string[], AnswerError>;
    guardOf: GuardOf;
  }>;
  extract: Readonly<{
    ask: (prompt: string, transport: ArmTransport) => Promise<Exchange>;
    read: (text: string) => Result<Extraction, AnswerError>;
  }>;
}>;
