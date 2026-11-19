// Pi session JSONL → Run. Pure: the caller supplies the file's text.
//
// A reclaw scheduled run is the session's first user message and everything up
// to the second one. A later user message is a Telegram reply that resumed the
// session (reclaw resumes the backend that ran), which is chat, not the skill.

import { z } from 'zod';
import {
  type FailureReason,
  type ModelRef,
  type Result,
  type Run,
  type RunOutcome,
  type ToolCall,
  err,
  modelKey,
  modelRef,
  ok,
} from './model.ts';

export type SessionError =
  | Readonly<{ kind: 'malformed-line'; line: number }>
  | Readonly<{ kind: 'no-header' }>
  | Readonly<{ kind: 'no-prompt' }>
  | Readonly<{ kind: 'no-model' }>;

const textBlock = z.object({ type: z.literal('text'), text: z.string() });
const toolCallBlock = z.object({
  type: z.literal('toolCall'),
  name: z.string(),
  arguments: z.record(z.string(), z.unknown()).default({}),
});
const anyBlock = z.object({ type: z.string() });

const usageSchema = z.object({
  input: z.number().default(0),
  output: z.number().default(0),
  reasoning: z.number().default(0),
});

const userMessage = z.object({
  role: z.literal('user'),
  content: z.union([z.string(), z.array(anyBlock.loose())]),
});
const assistantMessage = z.object({
  role: z.literal('assistant'),
  content: z.array(anyBlock.loose()).default([]),
  provider: z.string().optional(),
  model: z.string().optional(),
  stopReason: z.string().optional(),
  errorMessage: z.string().optional(),
  usage: usageSchema.optional(),
});
const toolResultMessage = z.object({
  role: z.literal('toolResult'),
  content: z.array(anyBlock.loose()).default([]),
});

const entrySchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('session'), id: z.string(), timestamp: z.string() }),
  z.object({ type: z.literal('model_change'), timestamp: z.string(), provider: z.string(), modelId: z.string() }),
  z.object({ type: z.literal('thinking_level_change'), timestamp: z.string(), thinkingLevel: z.string() }),
  // Harness-injected context (the cortex memory surface). No timestamp is guaranteed.
  z.object({ type: z.literal('custom_message'), content: z.union([z.string(), z.array(anyBlock.loose())]) }),
  z.object({
    type: z.literal('message'),
    timestamp: z.string(),
    message: z.union([userMessage, assistantMessage, toolResultMessage, z.object({ role: z.string() })]),
  }),
]);

type Entry = z.infer<typeof entrySchema>;
type Assistant = z.infer<typeof assistantMessage>;

/** One line, or `undefined` for entry types the retrospective does not read. */
const parseLine = (raw: string): Result<Entry | undefined, 'malformed'> => {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return err('malformed');
  }
  const head = z.object({ type: z.string() }).safeParse(json);
  if (!head.success) return err('malformed');
  const known = ['session', 'model_change', 'thinking_level_change', 'custom_message', 'message'];
  if (!known.includes(head.data.type)) return ok(undefined);
  const entry = entrySchema.safeParse(json);
  return entry.success ? ok(entry.data) : err('malformed');
};

/**
 * Parse every line. Only the final line may be unparsable: a process killed
 * mid-write leaves a torn tail, which is expected; corruption anywhere else is not.
 */
const parseEntries = (content: string): Result<readonly Entry[], SessionError> => {
  const lines = content.split('\n').filter((l) => l.trim().length > 0);
  const entries: Entry[] = [];
  for (const [i, line] of lines.entries()) {
    const parsed = parseLine(line);
    if (!parsed.ok) {
      if (i === lines.length - 1) break;
      return err({ kind: 'malformed-line', line: i + 1 });
    }
    if (parsed.value !== undefined) entries.push(parsed.value);
  }
  return ok(entries);
};

const textOf = (content: z.infer<typeof userMessage>['content']): string =>
  typeof content === 'string'
    ? content
    : content.flatMap((b) => {
        const t = textBlock.safeParse(b);
        return t.success ? [t.data.text] : [];
      }).join('\n');

const textBlocks = (blocks: readonly unknown[]): readonly string[] =>
  blocks.flatMap((b) => {
    const t = textBlock.safeParse(b);
    return t.success ? [t.data.text] : [];
  });

const stringArg = (args: Readonly<Record<string, unknown>>, key: string): string | undefined => {
  const v = args[key];
  return typeof v === 'string' ? v : undefined;
};

export const toToolCall = (name: string, args: Readonly<Record<string, unknown>>): ToolCall => {
  const path = stringArg(args, 'path');
  if (name === 'bash') {
    const command = stringArg(args, 'command');
    return command === undefined ? { kind: 'other', name } : { kind: 'bash', command };
  }
  if (path === undefined) return { kind: 'other', name };
  if (name === 'write') return { kind: 'write', path, content: stringArg(args, 'content') ?? '' };
  if (name === 'edit') return { kind: 'edit', path };
  if (name === 'read') return { kind: 'read', path };
  return { kind: 'other', name };
};

const toolCallsOf = (a: Assistant): readonly ToolCall[] =>
  a.content.flatMap((b) => {
    const call = toolCallBlock.safeParse(b);
    return call.success ? [toToolCall(call.data.name, call.data.arguments)] : [];
  });

/**
 * The outcome reclaw's runner would have produced from these assistant
 * messages: a reported error fails the run even after text; otherwise the last
 * text-bearing message is the delivery, and an exact ALL_CLEAR is suppressed.
 */
export const deriveOutcome = (assistants: readonly Assistant[]): RunOutcome => {
  const errors = assistants.filter((a) => a.stopReason === 'error');
  const lastError = errors.at(-1);
  if (lastError !== undefined) {
    const message = lastError.errorMessage?.trim() || 'pi reported an agent error';
    return failed({ kind: 'provider-error', message });
  }
  const last = assistants.at(-1);
  if (last?.stopReason === 'aborted') return failed({ kind: 'aborted' });

  const texts = assistants.flatMap((a) => {
    const blocks = textBlocks(a.content);
    return blocks.length > 0 ? [{ text: blocks.join('\n'), message: a }] : [];
  });
  const final = texts.at(-1);
  if (final === undefined || final.text.length === 0) return failed({ kind: 'no-text' });
  if (final.text.trim() === 'ALL_CLEAR') return { kind: 'all-clear' };
  return { kind: 'delivered', text: final.text, truncated: last?.stopReason === 'length' };
};

const failed = (reason: FailureReason): RunOutcome => ({ kind: 'failed', reason });

export const parseSession = (file: string, content: string): Result<Run, SessionError> => {
  const parsed = parseEntries(content);
  if (!parsed.ok) return parsed;
  const entries = parsed.value;

  const header = entries.find((e) => e.type === 'session');
  if (header === undefined) return err({ kind: 'no-header' });

  const isUser = (e: Entry): boolean => e.type === 'message' && e.message.role === 'user';
  const isModelTurn = (e: Entry): boolean =>
    e.type === 'message' && (e.message.role === 'assistant' || e.message.role === 'toolResult');
  const firstUser = entries.findIndex(isUser);
  if (firstUser < 0) return err({ kind: 'no-prompt' });
  const nextUser = entries.findIndex((e, i) => i > firstUser && isUser(e));
  const segment = entries.slice(firstUser, nextUser < 0 ? entries.length : nextUser);
  // The run is everything up to the model's last turn before any reply. A
  // resumed session writes model, thinking-level, system and memory entries
  // just before the reply; those belong to the chat, so nothing run-scoped
  // (end time, configured model, thinking level, injected context) reads past here.
  const lastTurn = segment.findLastIndex(isModelTurn);
  const scope = entries.slice(0, firstUser + (lastTurn < 0 ? 1 : lastTurn + 1));
  const lastOf = <K extends Entry['type']>(type: K): Extract<Entry, { type: K }> | undefined =>
    scope.findLast((e): e is Extract<Entry, { type: K }> => e.type === type);

  const prompt = ((): string => {
    const first = entries[firstUser];
    if (first?.type !== 'message') return '';
    const user = userMessage.safeParse(first.message);
    return user.success ? textOf(user.data.content) : '';
  })();

  const messages = segment.flatMap((e) => (e.type === 'message' ? [e.message] : []));
  const assistants = messages.flatMap((m) => {
    const a = assistantMessage.safeParse(m);
    return a.success ? [a.data] : [];
  });
  const toolOutputs = messages.flatMap((m) => {
    const r = toolResultMessage.safeParse(m);
    return r.success ? [textBlocks(r.data.content).join('\n')] : [];
  });
  const injected = scope.flatMap((e) => (e.type === 'custom_message' ? [textOf(e.content)] : []));

  const answered = assistants.flatMap((a) =>
    a.provider !== undefined && a.model !== undefined ? [modelRef(a.provider, a.model)] : [],
  );
  const configured = lastOf('model_change');
  const model: ModelRef | undefined =
    answered.at(-1) ?? (configured === undefined ? undefined : modelRef(configured.provider, configured.modelId));
  if (model === undefined) return err({ kind: 'no-model' });

  const thinking = lastOf('thinking_level_change');
  const lastEntry = lastOf('message');

  return ok({
    sessionId: header.id,
    file,
    startedAt: new Date(header.timestamp),
    endedAt: new Date(lastEntry !== undefined ? lastEntry.timestamp : header.timestamp),
    prompt,
    model,
    mixedModels: new Set(answered.map(modelKey)).size > 1,
    thinkingLevel: thinking?.thinkingLevel ?? null,
    toolCalls: assistants.flatMap(toolCallsOf),
    evidence: [...injected, ...toolOutputs],
    outcome: deriveOutcome(assistants),
    usage: assistants.reduce(
      (acc, a) => ({
        input: acc.input + (a.usage?.input ?? 0),
        output: acc.output + (a.usage?.output ?? 0),
        reasoning: acc.reasoning + (a.usage?.reasoning ?? 0),
      }),
      { input: 0, output: 0, reasoning: 0 },
    ),
  });
};
