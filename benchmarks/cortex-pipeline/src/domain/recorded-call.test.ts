import { describe, expect, test } from 'bun:test';
import { parseRecordedCall } from './recorded-call.ts';

const line = (o: unknown) => JSON.stringify(o);
const user = (content: unknown) => line({ type: 'user', timestamp: '2026-11-01T10:01:44.758Z', message: { role: 'user', content } });
const assistant = (model: string, id: string, content: unknown[]) =>
  line({ type: 'assistant', message: { id, model, role: 'assistant', content } });

const PROMPT = 'Classify relationships between memory pairs.\n\nMemory Pairs:\n…';

describe('parseRecordedCall', () => {
  test('joins the text blocks of the last answering message and records its model', () => {
    const content = [
      line({ type: 'queue-operation' }),
      user(PROMPT),
      assistant('claude-haiku-4-5', 'm1', [{ type: 'thinking', thinking: '' }]),
      assistant('claude-haiku-4-5', 'm1', [{ type: 'text', text: '```json\n[' }]),
      assistant('claude-haiku-4-5', 'm1', [{ type: 'text', text: ']\n```' }]),
      '{"torn": ',
    ].join('\n');
    const parsed = parseRecordedCall('s1', content);
    expect(parsed).toEqual({
      ok: true,
      value: {
        session: 's1',
        job: 'relate',
        at: new Date('2026-11-01T10:01:44.758Z'),
        prompt: PROMPT,
        reference: { kind: 'answered', model: 'claude-haiku-4-5', text: '```json\n[]\n```' },
      },
    } as never);
  });

  test('reads a prompt given as text blocks', () => {
    const parsed = parseRecordedCall('s2', [user([{ type: 'text', text: PROMPT }]), assistant('m', 'x', [{ type: 'text', text: 'ok' }])].join('\n'));
    expect(parsed.ok && parsed.value.prompt).toBe(PROMPT);
  });

  test('records an API failure (a <synthetic> message) as a failed reference', () => {
    const parsed = parseRecordedCall(
      's3',
      [user(PROMPT), assistant('<synthetic>', 'e', [{ type: 'text', text: "You've hit your weekly limit" }])].join('\n'),
    );
    expect(parsed.ok && parsed.value.reference).toEqual({ kind: 'failed', detail: "You've hit your weekly limit" });
  });

  test('is not a cortex call when the prompt does not open with a job line, even if it mentions one', () => {
    const parsed = parseRecordedCall(
      's4',
      [user(`please look at this: ${PROMPT}`), assistant('m', 'x', [{ type: 'text', text: 'ok' }])].join('\n'),
    );
    expect(parsed).toEqual({ ok: false, error: { kind: 'not-a-cortex-call' } });
  });

  test('reports a call that never got an answer', () => {
    expect(parseRecordedCall('s5', user(PROMPT))).toEqual({ ok: false, error: { kind: 'no-answer' } });
  });
});
