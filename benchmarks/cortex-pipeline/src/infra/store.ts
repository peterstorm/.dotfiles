// Files: the corpus and responses (personal, under the data directory) and
// protocols (ids and hashes only, committed).
//
// Responses are append-only JSONL, one file per protocol and arm, so a run that
// stops halfway resumes where it stopped: a case with a stored response is not
// asked again. Re-running an arm is therefore idempotent; asking again means
// deleting its file.

import { createHash } from 'node:crypto';
import { appendFile, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { z } from 'zod';
import { JOBS, type Job, type RecordedCall, SessionId } from '../domain/model.ts';
import type { Exchange } from '../domain/port.ts';
import type { ProtocolCase, Quotas } from '../domain/protocol.ts';

export const sha256 = (text: string): string => createHash('sha256').update(text).digest('hex');

const job = z.enum(JOBS);
const session = z.string().transform(SessionId);

// ─── Corpus ──────────────────────────────────────────────────────────────────

const recordedCall = z.object({
  session,
  job,
  at: z.coerce.date(),
  prompt: z.string(),
  reference: z.discriminatedUnion('kind', [
    z.object({ kind: z.literal('answered'), model: z.string(), text: z.string() }),
    z.object({ kind: z.literal('failed'), detail: z.string() }),
  ]),
});

export const writeCorpus = async (path: string, calls: readonly RecordedCall[]): Promise<string> => {
  await mkdir(dirname(path), { recursive: true });
  const body = calls.map((c) => JSON.stringify(c)).join('\n') + '\n';
  await Bun.write(path, body);
  return sha256(body);
};

const parseLines = <T>(content: string, schema: z.ZodType<T>, what: string): readonly T[] =>
  content
    .split('\n')
    .filter((l) => l.trim() !== '')
    .map((l, i) => {
      const raw: unknown = JSON.parse(l);
      const parsed = schema.safeParse(raw);
      if (!parsed.success) throw new Error(`${what} line ${i + 1}: ${parsed.error.message}`);
      return parsed.data;
    });

export const readCorpus = async (path: string): Promise<Readonly<{ calls: readonly RecordedCall[]; sha256: string }>> => {
  const content = await Bun.file(path).text();
  return { calls: parseLines(content, recordedCall, path), sha256: sha256(content) };
};

// ─── Protocol ────────────────────────────────────────────────────────────────

const protocolCase = z.object({
  job,
  session,
  at: z.string(),
  promptSha256: z.string(),
  referenceModel: z.string(),
  size: z.number(),
  stratum: z.string(),
});

const protocolFile = z.object({
  name: z.string(),
  id: z.string(),
  seed: z.number(),
  quotas: z.object({ relate: z.number(), prune: z.number(), extract: z.number() }),
  corpus: z.object({ calls: z.number(), sha256: z.string() }),
  cortexCommit: z.string(),
  cases: z.array(protocolCase),
});

export type Protocol = Readonly<{
  name: string;
  /** `<name>-<12 hex of the cases' hash>`: two protocols with one id ask the same cases. */
  id: string;
  seed: number;
  quotas: Quotas;
  corpus: Readonly<{ calls: number; sha256: string }>;
  cortexCommit: string;
  cases: readonly ProtocolCase[];
}>;

export const protocolId = (name: string, cases: readonly ProtocolCase[]): string =>
  `${name}-${sha256(JSON.stringify(cases)).slice(0, 12)}`;

export const writeProtocol = async (path: string, protocol: Protocol): Promise<void> => {
  await mkdir(dirname(path), { recursive: true });
  await Bun.write(path, JSON.stringify(protocol, null, 2) + '\n');
};

export const readProtocol = async (path: string): Promise<Protocol> => {
  const raw: unknown = JSON.parse(await Bun.file(path).text());
  const p = protocolFile.parse(raw);
  const expected = protocolId(p.name, p.cases);
  if (p.id !== expected) throw new Error(`protocol ${path}: id ${p.id} does not match its cases (${expected}); it was edited`);
  return p;
};

// ─── Responses ───────────────────────────────────────────────────────────────

const callMeta = z.object({
  latencyMs: z.number(),
  servedModel: z.string().nullable(),
  promptTokens: z.number().nullable(),
  completionTokens: z.number().nullable(),
});

const storedResponse = z.object({
  session,
  job,
  ranAt: z.string(),
  cortexCommit: z.string(),
  promptSha256: z.string(),
  promptChars: z.number(),
  request: z.object({
    timeoutMs: z.number(),
    maxTokens: z.number().nullable(),
    decoding: z.enum(['json-schema', 'json-object', 'none']),
  }),
  outcome: z.discriminatedUnion('kind', [
    z.object({ kind: z.literal('answered'), text: z.string(), direct: z.boolean(), meta: callMeta }),
    z.object({ kind: z.literal('failed'), error: z.string(), latencyMs: z.number() }),
  ]),
});

export type StoredResponse = z.infer<typeof storedResponse>;

export const responsesPath = (dataDir: string, protocol: string, armSlug: string): string =>
  join(dataDir, 'responses', protocol, `${armSlug}.jsonl`);

export const appendResponse = async (
  path: string,
  entry: Readonly<{ session: SessionId; job: Job; ranAt: Date; cortexCommit: string; exchange: Exchange }>,
): Promise<void> => {
  const { exchange } = entry;
  const line: StoredResponse = {
    session: entry.session,
    job: entry.job,
    ranAt: entry.ranAt.toISOString(),
    cortexCommit: entry.cortexCommit,
    promptSha256: sha256(exchange.prompt),
    promptChars: exchange.prompt.length,
    request: exchange.request,
    outcome: exchange.outcome,
  };
  await mkdir(dirname(path), { recursive: true });
  await appendFile(path, JSON.stringify(line) + '\n');
};

export const readResponses = async (path: string): Promise<readonly StoredResponse[]> => {
  const file = Bun.file(path);
  if (!(await file.exists())) return [];
  return parseLines(await file.text(), storedResponse, path);
};
