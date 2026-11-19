// Anti-corruption layer over a cortex checkout.
//
// Cortex is loaded from a directory at run time (the deployed plugin by
// default), so a benchmark run measures exactly the prompts, request specs and
// parsers that checkout ships, and records which commit that was. Cortex's
// values are parsed into the benchmark's own types here; nothing past this file
// sees a cortex type.

import { join } from 'node:path';
import { z } from 'zod';
import type { Extraction } from '../domain/extract.ts';
import { EDGE_RELATIONS, MEMORY_TYPES, type Result, err, ok } from '../domain/model.ts';
import type {
  AnswerError,
  ArmTransport,
  CortexJobs,
  Exchange,
  RequestOptions,
  RequestSpec,
  TransportReply,
} from '../domain/port.ts';
import type { ArchiveGuard, PruneRow } from '../domain/prune.ts';
import type { MemoryPair, PairLabel } from '../domain/relate.ts';

// ─── Cortex's signatures, as declared in its sources ─────────────────────────

type CortexTransport = (
  prompt: string,
  timeoutMs: number,
  options?: RequestOptions,
) => Promise<{ text: string; direct: boolean }>;

type CortexMemoryPair = Readonly<{
  source: Readonly<{ id: string; content: string; summary: string; memory_type: string }>;
  target: Readonly<{ id: string; content: string; summary: string; memory_type: string }>;
}>;

type CortexPruneMemory = Readonly<{
  id: string;
  memory_type: string;
  summary: string;
  confidence: number;
  access_count: number;
  pinned: boolean;
  created_at: string;
}>;

/** The cortex functions the benchmark calls. Each is checked to exist at load; behaviour is pinned by the contract test. */
export type CortexModule = Readonly<{
  classifyEdges: (pairs: readonly CortexMemoryPair[], transport: CortexTransport) => Promise<unknown>;
  buildEdgeClassificationPrompt: (pairs: readonly CortexMemoryPair[]) => string;
  parseEdgeClassificationResponse: (text: string, options: { strict: boolean }) => unknown;
  joinClassificationsToPairs: (batch: readonly { pair: CortexMemoryPair }[], classifications: readonly unknown[]) => unknown;
  buildPrunePrompt: (memories: readonly CortexPruneMemory[]) => string;
  requestPruneCandidates: (prompt: string, transport: CortexTransport) => Promise<string>;
  parsePruneResponse: (text: string) => unknown;
  archiveGuardFor: (memory: Readonly<{ pinned: boolean; memory_type: string; confidence: number; created_at: string }>, now: Date) => unknown;
  extractMemories: (prompt: string, transport: CortexTransport) => Promise<string>;
  parseExtractionResponse: (text: string) => unknown;
  runLlmPrompt: (prompt: string, timeoutMs: number, thinking?: string) => Promise<string>;
  chatCompletion: (endpoint: CortexEndpoint, prompt: string, options: RequestOptions & { timeoutMs?: number }) => Promise<unknown>;
  resolveOpenAiCompatEndpoint: () => CortexEndpoint | null;
  EDGE_RELATIONS: unknown;
  MEMORY_TYPES: unknown;
}>;

export type CortexEndpoint = Readonly<{ baseUrl: string; apiKey: string; model: string }>;

const SOURCES = {
  llm: 'engine/src/infra/claude-llm.ts',
  client: 'engine/src/infra/llm-client.ts',
  prune: 'engine/src/commands/ai-prune.ts',
  edges: 'engine/src/commands/semantic-edges.ts',
  extraction: 'engine/src/core/extraction.ts',
  types: 'engine/src/core/types.ts',
} as const;

export type CortexLoadError = Readonly<{ kind: 'cortex-missing-export'; root: string; names: readonly string[] }>;

const NEEDED: Readonly<Record<keyof CortexModule, keyof typeof SOURCES>> = {
  classifyEdges: 'llm',
  buildEdgeClassificationPrompt: 'llm',
  parseEdgeClassificationResponse: 'llm',
  extractMemories: 'llm',
  runLlmPrompt: 'llm',
  chatCompletion: 'client',
  resolveOpenAiCompatEndpoint: 'client',
  buildPrunePrompt: 'prune',
  requestPruneCandidates: 'prune',
  parsePruneResponse: 'prune',
  archiveGuardFor: 'prune',
  joinClassificationsToPairs: 'edges',
  parseExtractionResponse: 'extraction',
  EDGE_RELATIONS: 'types',
  MEMORY_TYPES: 'types',
};

/**
 * Import the cortex functions from a checkout. Fails with the names a checkout
 * lacks (an older cortex without the transport seam on every job, say) rather
 * than at the first call.
 */
export const loadCortex = async (root: string): Promise<Result<CortexModule, CortexLoadError>> => {
  const modules = new Map<string, Record<string, unknown>>();
  for (const [key, path] of Object.entries(SOURCES)) {
    const mod: Record<string, unknown> = await import(join(root, path));
    modules.set(key, mod);
  }
  const found: Record<string, unknown> = {};
  const missing: string[] = [];
  for (const [name, source] of Object.entries(NEEDED)) {
    const value = modules.get(source)?.[name];
    if (value === undefined) missing.push(name);
    else found[name] = value;
  }
  if (missing.length > 0) return err({ kind: 'cortex-missing-export', root, names: missing });
  // Every name was found above; the signatures are cortex's own, pinned by test/cortex-contract.test.ts.
  return ok(found as CortexModule);
};

/** Cortex's vocabularies differ from the benchmark's mirror: the mirror must be updated before any run is graded. */
export const vocabularyDrift = (cortex: CortexModule): readonly string[] => {
  const list = z.array(z.string());
  const relations = list.safeParse(cortex.EDGE_RELATIONS);
  const types = list.safeParse(cortex.MEMORY_TYPES);
  const same = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((x, i) => x === b[i]);
  return [
    ...(relations.success && same(relations.data, EDGE_RELATIONS) ? [] : ['EDGE_RELATIONS']),
    ...(types.success && same(types.data, MEMORY_TYPES) ? [] : ['MEMORY_TYPES']),
  ];
};

// ─── Cortex outputs, parsed ──────────────────────────────────────────────────

const classification = z.object({
  pair_index: z.number().optional(),
  source_id: z.string(),
  target_id: z.string(),
  relation_type: z.enum(EDGE_RELATIONS),
  strength: z.number(),
});
type Classification = z.infer<typeof classification>;

const classificationOutcome = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('ok'), classifications: z.array(classification) }),
  z.object({ kind: z.literal('unparseable'), reason: z.string() }),
]);

const classificationJoin = z.union([
  z.object({ ok: z.literal(true), byOrdinal: z.literal(true), byIndex: z.instanceof(Map) }),
  z.object({ ok: z.literal(true), byOrdinal: z.literal(false), byKey: z.instanceof(Map) }),
  z.object({ ok: z.literal(false), reason: z.string() }),
]);

const pruneOutcome = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('ok'), candidates: z.array(z.object({ id: z.string(), reason: z.string() })) }),
  z.object({ kind: z.literal('unparseable'), reason: z.string() }),
]);

const extractionOutcome = z.discriminatedUnion('kind', [
  z.object({
    kind: z.literal('ok'),
    memories: z.array(z.object({ summary: z.string(), content: z.string(), memory_type: z.string(), scope: z.string() })),
    entities: z.array(z.unknown()),
  }),
  z.object({ kind: z.literal('parse_error'), reason: z.string() }),
]);

const guard = z.enum(['pinned', 'stable', 'too-young']).nullable();

const completion = z.object({
  content: z.string(),
  model: z.string(),
  promptTokens: z.number().nullable(),
  completionTokens: z.number().nullable(),
});

const describe = (e: unknown): string => (e instanceof Error ? e.message : String(e));

const corrupt = (reason: string): AnswerError => ({ kind: 'corrupt', reason });
const unparseable = (reason: string): AnswerError => ({ kind: 'unparseable', reason });

const toCortexPair = (p: MemoryPair): CortexMemoryPair => ({ source: p.source, target: p.target });

/** Rows carry the creation day only; midnight UTC is the instant cortex's age guard is asked about. */
const createdAt = (row: PruneRow): string => `${row.created_day}T00:00:00.000Z`;

const toPruneMemory = (row: PruneRow): CortexPruneMemory => ({
  id: row.id,
  memory_type: row.memory_type,
  summary: row.summary,
  confidence: row.confidence,
  access_count: row.access_count,
  pinned: row.pinned,
  created_at: createdAt(row),
});

const requestSpec = (timeoutMs: number, options: RequestOptions | undefined): RequestSpec => ({
  timeoutMs,
  maxTokens: options?.maxTokens ?? null,
  decoding: options?.jsonSchema !== undefined ? 'json-schema' : options?.jsonMode === true ? 'json-object' : 'none',
});

/**
 * Send one job request through `send`, capturing what the job asked and what
 * the arm answered. Cortex's own post-processing (its strict parse can throw
 * after a successful call) is not the exchange: `read` re-parses the captured
 * text with the same parser, so a parse failure is graded, not lost.
 */
const capture = async (
  transport: ArmTransport,
  send: (t: CortexTransport) => Promise<unknown>,
): Promise<Exchange> => {
  let sent: { prompt: string; request: RequestSpec } | undefined;
  let reply: TransportReply | undefined;
  let failure: { error: string; latencyMs: number } | undefined;
  const recording: CortexTransport = async (prompt, timeoutMs, options) => {
    sent = { prompt, request: requestSpec(timeoutMs, options) };
    const started = performance.now();
    try {
      reply = await transport(prompt, timeoutMs, options);
      return { text: reply.text, direct: reply.direct };
    } catch (e) {
      failure = { error: describe(e), latencyMs: Math.round(performance.now() - started) };
      throw e;
    }
  };
  try {
    await send(recording);
  } catch {
    // Either the transport failed (recorded in `failure`) or cortex rejected a
    // reply it received (recorded in `reply`, graded by `read`). Nothing else
    // can throw here: the job functions do no other I/O.
  }
  if (sent === undefined) throw new Error('cortex job returned without sending a request');
  if (reply !== undefined) {
    return { ...sent, outcome: { kind: 'answered', text: reply.text, direct: reply.direct, meta: reply.meta } };
  }
  return { ...sent, outcome: { kind: 'failed', error: failure?.error ?? 'unknown failure', latencyMs: failure?.latencyMs ?? 0 } };
};

const labelsFromJoin = (
  pairs: readonly MemoryPair[],
  joined: z.infer<typeof classificationJoin>,
): Result<readonly PairLabel[], AnswerError> => {
  if (!joined.ok) return err(corrupt(joined.reason));
  const label = (c: unknown): PairLabel => {
    const parsed = classification.safeParse(c);
    return parsed.success ? { kind: 'edge', relation: parsed.data.relation_type, strength: parsed.data.strength } : { kind: 'none' };
  };
  return ok(
    pairs.map((p, i) =>
      joined.byOrdinal ? label(joined.byIndex.get(i + 1)) : label(joined.byKey.get(`${p.source.id}:${p.target.id}`)),
    ),
  );
};

/**
 * Relate answers are read the way the semantic-edges batch worker reads them:
 * parse (strict for a direct answer, tolerant for subprocess output), then join
 * to the batch's pairs. A strict parse failure throws in cortex; here it is an
 * unparseable answer.
 */
const readRelate =
  (cortex: CortexModule) =>
  (pairs: readonly MemoryPair[], text: string, direct: boolean): Result<readonly PairLabel[], AnswerError> => {
    let outcome: z.infer<typeof classificationOutcome>;
    try {
      const parsed = classificationOutcome.safeParse(cortex.parseEdgeClassificationResponse(text, { strict: direct }));
      if (!parsed.success) return err(unparseable(`unexpected parser output: ${parsed.error.message}`));
      outcome = parsed.data;
    } catch (e) {
      return err(unparseable(describe(e)));
    }
    if (outcome.kind === 'unparseable') return err(unparseable(outcome.reason));
    const classifications: readonly Classification[] = outcome.classifications;
    const joined = classificationJoin.safeParse(
      cortex.joinClassificationsToPairs(pairs.map((p) => ({ pair: toCortexPair(p) })), classifications),
    );
    if (!joined.success) return err(corrupt(`unexpected join output: ${joined.error.message}`));
    return labelsFromJoin(pairs, joined.data);
  };

const readPrune =
  (cortex: CortexModule) =>
  (text: string): Result<readonly string[], AnswerError> => {
    const parsed = pruneOutcome.safeParse(cortex.parsePruneResponse(text));
    if (!parsed.success) return err(unparseable(`unexpected parser output: ${parsed.error.message}`));
    return parsed.data.kind === 'ok' ? ok(parsed.data.candidates.map((c) => c.id)) : err(unparseable(parsed.data.reason));
  };

const readExtraction =
  (cortex: CortexModule) =>
  (text: string): Result<Extraction, AnswerError> => {
    const parsed = extractionOutcome.safeParse(cortex.parseExtractionResponse(text));
    if (!parsed.success) return err(unparseable(`unexpected parser output: ${parsed.error.message}`));
    const outcome = parsed.data;
    return outcome.kind === 'ok'
      ? ok({ memories: outcome.memories, entities: outcome.entities.length })
      : err(unparseable(outcome.reason));
  };

export const cortexJobs = (cortex: CortexModule): CortexJobs => ({
  relate: {
    ask: (pairs, transport) => capture(transport, (t) => cortex.classifyEdges(pairs.map(toCortexPair), t)),
    read: readRelate(cortex),
  },
  prune: {
    ask: (rows, transport) =>
      capture(transport, (t) => cortex.requestPruneCandidates(cortex.buildPrunePrompt(rows.map(toPruneMemory)), t)),
    read: readPrune(cortex),
    guardOf: (row, now): ArchiveGuard | null => {
      const parsed = guard.safeParse(
        cortex.archiveGuardFor(
          { pinned: row.pinned, memory_type: row.memory_type, confidence: row.confidence, created_at: createdAt(row) },
          now,
        ),
      );
      // An unrecognised guard from a newer cortex keeps the memory: the safe direction, as in cortex.
      return parsed.success ? parsed.data : 'stable';
    },
  },
  extract: {
    ask: (prompt, transport) => capture(transport, (t) => cortex.extractMemories(prompt, t)),
    read: readExtraction(cortex),
  },
});

/** The prompts cortex builds today, for contract tests and for hashing what an arm was asked. */
export const cortexPrompts = (cortex: CortexModule) => ({
  relate: (pairs: readonly MemoryPair[]): string => cortex.buildEdgeClassificationPrompt(pairs.map(toCortexPair)),
  prune: (rows: readonly PruneRow[]): string => cortex.buildPrunePrompt(rows.map(toPruneMemory)),
});

/** Parse cortex's chatCompletion result (direct arms). */
export const parseCompletion = (value: unknown): z.infer<typeof completion> => completion.parse(value);
