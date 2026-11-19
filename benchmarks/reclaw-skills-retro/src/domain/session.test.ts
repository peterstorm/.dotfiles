import { describe, expect, test } from 'bun:test';
import { deriveOutcome, parseSession, toToolCall } from './session.ts';

const line = (o: unknown): string => JSON.stringify(o);
const header = line({ type: 'session', version: 3, id: 'sess-1', timestamp: '2026-10-01T05:35:00.000Z', cwd: '/w' });
const modelChange = line({
  type: 'model_change',
  timestamp: '2026-10-01T05:35:01.000Z',
  provider: 'desktop-vllm',
  modelId: 'glm-5.3-flash-spark-tp2-v14',
});
const user = (text: string, ts: string): string =>
  line({ type: 'message', timestamp: ts, message: { role: 'user', content: [{ type: 'text', text }] } });
const assistant = (ts: string, content: unknown[], extra: Record<string, unknown> = {}): string =>
  line({
    type: 'message',
    timestamp: ts,
    message: {
      role: 'assistant',
      provider: 'desktop-vllm',
      model: 'glm-5.3-flash-spark-tp2-v14',
      stopReason: 'stop',
      content,
      usage: { input: 100, output: 20, reasoning: 5 },
      ...extra,
    },
  });
const toolResult = (ts: string, text: string): string =>
  line({ type: 'message', timestamp: ts, message: { role: 'toolResult', content: [{ type: 'text', text }] } });

const parse = (...lines: string[]) => parseSession('/s/2026-10-01T05-35-00-000Z_sess-1.jsonl', lines.join('\n'));

describe('deriveOutcome mirrors reclaw runner semantics', () => {
  const msg = (stopReason: string, texts: string[], errorMessage?: string) => ({
    role: 'assistant' as const,
    stopReason,
    content: texts.map((text) => ({ type: 'text', text })),
    ...(errorMessage === undefined ? {} : { errorMessage }),
  });

  test('a provider error fails the run even after text', () => {
    expect(deriveOutcome([msg('stop', ['partial']), msg('error', [], 'Connection error.')])).toEqual({
      kind: 'failed',
      reason: { kind: 'provider-error', message: 'Connection error.' },
    });
  });

  test('the last text-bearing message is the delivery, not narration before tools', () => {
    expect(deriveOutcome([msg('toolUse', ['Let me check']), msg('toolUse', []), msg('stop', ['Report'])])).toEqual({
      kind: 'delivered',
      text: 'Report',
      truncated: false,
    });
  });

  test('exactly ALL_CLEAR after trimming is suppressed; decorated is delivered', () => {
    expect(deriveOutcome([msg('stop', ['  ALL_CLEAR\n'])])).toEqual({ kind: 'all-clear' });
    expect(deriveOutcome([msg('stop', ['`ALL_CLEAR`'])]).kind).toBe('delivered');
  });

  test('no text at all, aborted and length-capped runs', () => {
    expect(deriveOutcome([msg('toolUse', [])])).toEqual({ kind: 'failed', reason: { kind: 'no-text' } });
    expect(deriveOutcome([msg('aborted', ['x'])])).toEqual({ kind: 'failed', reason: { kind: 'aborted' } });
    expect(deriveOutcome([msg('length', ['cut off'])])).toEqual({ kind: 'delivered', text: 'cut off', truncated: true });
  });
});

describe('parseSession', () => {
  test('recovers prompt, model, tool calls and evidence', () => {
    const r = parse(
      header,
      modelChange,
      line({ type: 'custom_message', customType: 'cortex-memory', content: 'PR #58 merged' }),
      user('Run the sync', '2026-10-01T05:35:02.000Z'),
      assistant('2026-10-01T05:35:05.000Z', [
        { type: 'toolCall', id: 't1', name: 'bash', arguments: { command: 'bun garmin-fetch.ts 2026-10-01' } },
      ], { stopReason: 'toolUse' }),
      toolResult('2026-10-01T05:35:09.000Z', '{"score": 81}'),
      assistant('2026-10-01T05:36:00.000Z', [{ type: 'text', text: 'Sleep score 81' }]),
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.prompt).toBe('Run the sync');
    expect(r.value.model).toEqual({ provider: 'desktop-vllm', model: 'glm-5.3-flash-spark-tp2-v14', class: 'local' });
    expect(r.value.toolCalls).toEqual([{ kind: 'bash', command: 'bun garmin-fetch.ts 2026-10-01' }]);
    expect(r.value.evidence).toEqual(['PR #58 merged', '{"score": 81}']);
    expect(r.value.outcome).toEqual({ kind: 'delivered', text: 'Sleep score 81', truncated: false });
    expect(r.value.usage).toEqual({ input: 200, output: 40, reasoning: 10 });
    expect(r.value.endedAt.toISOString()).toBe('2026-10-01T05:36:00.000Z');
  });

  test('a later user message is a Telegram reply: the run stops before it and ends at its last model turn', () => {
    const r = parse(
      header,
      user('scheduled prompt', '2026-10-01T05:35:02.000Z'),
      assistant('2026-10-01T05:36:00.000Z', [{ type: 'text', text: 'ALL_CLEAR' }]),
      modelChange.replace('05:35:01', '07:00:00'),
      line({ type: 'message', timestamp: '2026-10-01T07:00:00.500Z', message: { role: 'system' } }),
      user('why?', '2026-10-01T07:00:01.000Z'),
      assistant('2026-10-01T07:00:30.000Z', [{ type: 'text', text: 'Because…' }]),
    );
    expect(r.ok && r.value.outcome).toEqual({ kind: 'all-clear' });
    expect(r.ok && r.value.endedAt.toISOString()).toBe('2026-10-01T05:36:00.000Z');
  });

  test('entries written when a reply resumes the session do not leak into the run', () => {
    const r = parse(
      header,
      modelChange,
      line({ type: 'thinking_level_change', timestamp: '2026-10-01T05:35:01.000Z', thinkingLevel: 'low' }),
      user('scheduled prompt', '2026-10-01T05:35:02.000Z'),
      assistant('2026-10-01T05:36:00.000Z', [{ type: 'text', text: 'Report' }]),
      line({ type: 'thinking_level_change', timestamp: '2026-10-01T07:00:00.000Z', thinkingLevel: 'max' }),
      line({ type: 'custom_message', content: 'memory surface injected for the reply' }),
      user('why?', '2026-10-01T07:00:01.000Z'),
    );
    expect(r.ok && r.value.thinkingLevel).toBe('low');
    expect(r.ok && r.value.evidence).toEqual([]);
  });

  test('a run that never got an answer falls back to the configured model', () => {
    const r = parse(header, modelChange, user('p', '2026-10-01T05:35:02.000Z'));
    expect(r.ok && r.value.model.model).toBe('glm-5.3-flash-spark-tp2-v14');
    expect(r.ok && r.value.outcome).toEqual({ kind: 'failed', reason: { kind: 'no-text' } });
  });

  test('a torn final line is tolerated; corruption elsewhere is an error', () => {
    const ok = parse(header, user('p', '2026-10-01T05:35:02.000Z'), assistant('2026-10-01T05:35:03.000Z', [{ type: 'text', text: 'x' }]), '{"type":"mess');
    expect(ok.ok).toBe(true);
    expect(parse(header, '{not json', user('p', '2026-10-01T05:35:02.000Z'))).toEqual({
      ok: false,
      error: { kind: 'malformed-line', line: 2 },
    });
  });

  test('sessions without a header or a prompt are reported, not guessed', () => {
    expect(parse(user('p', '2026-10-01T05:35:02.000Z'))).toEqual({ ok: false, error: { kind: 'no-header' } });
    expect(parse(header, modelChange)).toEqual({ ok: false, error: { kind: 'no-prompt' } });
    expect(parse(header, user('p', '2026-10-01T05:35:02.000Z'))).toEqual({ ok: false, error: { kind: 'no-model' } });
  });
});

describe('toToolCall', () => {
  test('maps Pi tools by name and falls back to other when arguments are missing', () => {
    expect(toToolCall('write', { path: '/a.md', content: 'x' })).toEqual({ kind: 'write', path: '/a.md', content: 'x' });
    expect(toToolCall('edit', { path: '/a.md', edits: [] })).toEqual({ kind: 'edit', path: '/a.md' });
    expect(toToolCall('read', { path: '/a.md', limit: 5 })).toEqual({ kind: 'read', path: '/a.md' });
    expect(toToolCall('bash', {})).toEqual({ kind: 'other', name: 'bash' });
    expect(toToolCall('grep', { path: '/', pattern: 'x' })).toEqual({ kind: 'other', name: 'grep' });
  });
});
