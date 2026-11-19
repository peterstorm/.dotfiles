// Claude Code session JSONL → RecordedCall.
//
// Cortex's subprocess path pipes its prompt into `claude -p`, so each call is a
// one-turn session: the first user message is the prompt, and the last
// assistant message's text is what cortex received. Claude Code writes one
// entry per content block, so a message's text is the concatenation of the
// text blocks of every entry carrying its message id. An API failure is written
// as an assistant entry from model `<synthetic>`.

import { z } from 'zod';
import { type Job, type RecordedCall, type Result, SessionId, err, ok } from './model.ts';

/** The first line of each job's prompt, as cortex builds it. */
export const PROMPT_OPENINGS: ReadonlyArray<readonly [Job, string]> = [
  ['relate', 'Classify relationships between memory pairs.'],
  ['prune', "You are a memory pruner for a developer's persistent memory system."],
  ['extract', 'Extract memories from this Claude Code session transcript.'],
];

export const jobOfPrompt = (prompt: string): Job | undefined =>
  PROMPT_OPENINGS.find(([, opening]) => prompt.startsWith(opening))?.[0];

const SYNTHETIC_MODEL = '<synthetic>';

const textBlock = z.object({ type: z.literal('text'), text: z.string() });
const anyBlock = z.object({ type: z.string() }).loose();

const userEntry = z.object({
  type: z.literal('user'),
  timestamp: z.string(),
  message: z.object({ content: z.union([z.string(), z.array(anyBlock)]) }),
});

const assistantEntry = z.object({
  type: z.literal('assistant'),
  message: z.object({
    id: z.string().optional(),
    model: z.string(),
    content: z.array(anyBlock),
  }),
});

type UserEntry = z.infer<typeof userEntry>;
type AssistantEntry = z.infer<typeof assistantEntry>;

export type SessionError =
  | Readonly<{ kind: 'not-a-cortex-call' }>
  | Readonly<{ kind: 'no-answer' }>
  | Readonly<{ kind: 'bad-timestamp'; raw: string }>;

const textOf = (blocks: readonly unknown[]): string =>
  blocks.flatMap((b) => {
    const parsed = textBlock.safeParse(b);
    return parsed.success ? [parsed.data.text] : [];
  }).join('');

const promptOf = (entry: UserEntry): string =>
  typeof entry.message.content === 'string' ? entry.message.content : textOf(entry.message.content);

const parseJsonLine = (line: string): unknown => {
  try {
    return JSON.parse(line);
  } catch {
    // A torn line (a session still being written, or killed mid-write) carries
    // nothing this reader uses; the entries around it still parse.
    return undefined;
  }
};

/**
 * One session file's content → the cortex call it recorded. Sessions that are
 * not a cortex background call (an interactive session that merely mentions a
 * prompt) are `not-a-cortex-call`: the prompt must open with a job's first line.
 */
export const parseRecordedCall = (session: string, content: string): Result<RecordedCall, SessionError> => {
  const users: UserEntry[] = [];
  const assistants: AssistantEntry[] = [];
  for (const line of content.split('\n')) {
    if (line.trim() === '') continue;
    const raw = parseJsonLine(line);
    const user = userEntry.safeParse(raw);
    if (user.success) {
      users.push(user.data);
      continue;
    }
    const assistant = assistantEntry.safeParse(raw);
    if (assistant.success) assistants.push(assistant.data);
  }

  const first = users[0];
  if (first === undefined) return err({ kind: 'not-a-cortex-call' });
  const prompt = promptOf(first);
  const job = jobOfPrompt(prompt);
  if (job === undefined) return err({ kind: 'not-a-cortex-call' });

  const at = new Date(first.timestamp);
  if (Number.isNaN(at.getTime())) return err({ kind: 'bad-timestamp', raw: first.timestamp });

  const last = assistants.findLast((a) => textOf(a.message.content).length > 0);
  if (last === undefined) return err({ kind: 'no-answer' });
  const id = last.message.id;
  const text =
    id === undefined
      ? textOf(last.message.content)
      : assistants.filter((a) => a.message.id === id).map((a) => textOf(a.message.content)).join('');

  const reference =
    last.message.model === SYNTHETIC_MODEL
      ? ({ kind: 'failed', detail: text.slice(0, 200) } as const)
      : ({ kind: 'answered', model: last.message.model, text } as const);

  return ok({ session: SessionId(session), job, at, prompt, reference });
};
