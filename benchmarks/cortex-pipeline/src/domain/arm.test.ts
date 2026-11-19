import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { armSlug, parseArm } from './arm.ts';
import { classifyTransportError } from './failure.ts';

describe('parseArm', () => {
  test('reads each transport, keeping slashes inside a model id', () => {
    expect(parseArm('direct:desktop-vllm/Qwen/Qwen3-8B')).toEqual({
      ok: true,
      value: { kind: 'direct', id: 'direct:desktop-vllm/Qwen/Qwen3-8B', provider: 'desktop-vllm', model: 'Qwen/Qwen3-8B', decoding: 'guided' },
    });
    expect(parseArm('direct:desktop-vllm/glm-5.3+unguided').ok && parseArm('direct:desktop-vllm/glm-5.3+unguided')).toMatchObject({
      value: { model: 'glm-5.3', decoding: 'unguided' },
    });
    expect(parseArm('claude:claude-haiku-4-5')).toMatchObject({ ok: true, value: { kind: 'claude', model: 'claude-haiku-4-5' } });
    expect(parseArm('pi:github-copilot/claude-haiku-5.5')).toMatchObject({
      ok: true,
      value: { kind: 'pi', provider: 'github-copilot', model: 'claude-haiku-5.5' },
    });
  });

  test('rejects what it cannot place', () => {
    for (const spec of ['haiku', 'direct:', 'direct:provider', 'direct:/model', 'claude:', 'claude:a/b', 'pi:x', 'ollama:x/y']) {
      expect(parseArm(spec).ok).toBe(false);
    }
  });
});

describe('armSlug', () => {
  test('is file-name safe and decodes back to the arm id', () => {
    fc.assert(
      fc.property(fc.string({ minLength: 1 }), fc.string({ minLength: 1 }), (provider, model) => {
        fc.pre(!provider.includes('/') && !provider.includes(':'));
        const arm = parseArm(`direct:${provider}/${model}`);
        fc.pre(arm.ok);
        if (!arm.ok) return;
        const slug = armSlug(arm.value);
        expect(slug).toMatch(/^[A-Za-z0-9._+%-]+$/);
        expect(decodeURIComponent(slug)).toBe(arm.value.id);
      }),
    );
  });
});

describe('classifyTransportError', () => {
  test("names cortex's own error messages", () => {
    expect(classifyTransportError('LLM API returned only reasoning_content (content empty): the served model is thinking')).toBe('reasoning-only');
    expect(classifyTransportError('LLM output truncated (max_tokens=5120 reached, finish_reason=length)')).toBe('truncated');
    expect(classifyTransportError('LLM request timed out after 90000ms')).toBe('timeout');
    expect(classifyTransportError('LLM API returned empty content')).toBe('empty');
    expect(classifyTransportError('LLM API 429: quota exceeded')).toBe('refused');
    expect(classifyTransportError('LLM API 503: overloaded')).toBe('server-error');
    expect(classifyTransportError('Unable to connect. Is the computer able to access the url?')).toBe('network');
    expect(classifyTransportError('Extraction LLM CLI exited with code 1: boom')).toBe('cli-exit');
    expect(classifyTransportError('something new')).toBe('other');
  });
});
