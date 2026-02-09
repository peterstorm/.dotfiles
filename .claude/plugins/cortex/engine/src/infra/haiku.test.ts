/**
 * Tests for Haiku API client.
 * All tests use mocked Anthropic SDK - no real API calls.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  extractMemories,
  classifyEdges,
  isHaikuAvailable,
  type MemoryPair,
} from './haiku.js';

// Mock Anthropic SDK at module level
const mockCreate = vi.fn();

vi.mock('@anthropic-ai/sdk', () => {
  return {
    default: class MockAnthropic {
      messages = {
        create: mockCreate,
      };
    },
  };
});

describe('isHaikuAvailable', () => {
  it('returns true for non-empty string', () => {
    expect(isHaikuAvailable('sk-ant-123')).toBe(true);
  });

  it('returns false for undefined', () => {
    expect(isHaikuAvailable(undefined)).toBe(false);
  });

  it('returns false for empty string', () => {
    expect(isHaikuAvailable('')).toBe(false);
  });

  it('returns false for whitespace-only string', () => {
    expect(isHaikuAvailable('   ')).toBe(false);
  });
});

describe('extractMemories', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('returns raw response text from Haiku', async () => {
    const responseText = JSON.stringify([
      {
        content: 'Test memory',
        summary: 'Summary',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.8,
        priority: 7,
        tags: ['test'],
      },
    ]);

    mockCreate.mockResolvedValue({
      content: [
        {
          type: 'text',
          text: responseText,
        },
      ],
    });

    const prompt = 'Extract memories from: test transcript';
    const result = await extractMemories(prompt, 'sk-ant-test');

    expect(result).toBe(responseText);
    expect(mockCreate).toHaveBeenCalledWith({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 4096,
      temperature: 0,
      messages: [
        {
          role: 'user',
          content: prompt,
        },
      ],
    });
  });

  it('throws error when no text content in response', async () => {
    mockCreate.mockResolvedValue({
      content: [],
    });

    await expect(
      extractMemories('test prompt', 'sk-ant-test')
    ).rejects.toThrow('No text content in Haiku response');
  });

  it('throws error with context when API call fails', async () => {
    mockCreate.mockRejectedValue(
      new Error('API rate limit exceeded')
    );

    await expect(
      extractMemories('test prompt', 'sk-ant-test')
    ).rejects.toThrow('Haiku extraction failed: API rate limit exceeded');
  });

  it('handles non-Error exceptions', async () => {
    mockCreate.mockRejectedValue('string error');

    await expect(
      extractMemories('test prompt', 'sk-ant-test')
    ).rejects.toThrow('Haiku extraction failed: string error');
  });
});

describe('classifyEdges', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('returns parsed edge classifications', async () => {
    const responseText = JSON.stringify([
      {
        source_id: 'mem1',
        target_id: 'mem2',
        relation_type: 'relates_to',
        strength: 0.85,
      },
      {
        source_id: 'mem2',
        target_id: 'mem3',
        relation_type: 'derived_from',
        strength: 0.7,
      },
    ]);

    mockCreate.mockResolvedValue({
      content: [
        {
          type: 'text',
          text: responseText,
        },
      ],
    });

    const pairs: MemoryPair[] = [
      {
        source: {
          id: 'mem1',
          content: 'Memory 1 content',
          summary: 'Memory 1 summary',
          memory_type: 'decision',
        },
        target: {
          id: 'mem2',
          content: 'Memory 2 content',
          summary: 'Memory 2 summary',
          memory_type: 'pattern',
        },
      },
    ];

    const result = await classifyEdges(pairs, 'sk-ant-test');

    expect(result).toEqual([
      {
        source_id: 'mem1',
        target_id: 'mem2',
        relation_type: 'relates_to',
        strength: 0.85,
      },
      {
        source_id: 'mem2',
        target_id: 'mem3',
        relation_type: 'derived_from',
        strength: 0.7,
      },
    ]);
  });

  it('returns empty array for empty pairs without API call', async () => {
    const result = await classifyEdges([], 'sk-ant-test');

    expect(result).toEqual([]);
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('handles JSON in markdown code blocks', async () => {
    const responseText = `
Here are the classifications:

\`\`\`json
[
  {
    "source_id": "mem1",
    "target_id": "mem2",
    "relation_type": "refines",
    "strength": 0.9
  }
]
\`\`\`
`;

    mockCreate.mockResolvedValue({
      content: [
        {
          type: 'text',
          text: responseText,
        },
      ],
    });

    const pairs: MemoryPair[] = [
      {
        source: {
          id: 'mem1',
          content: 'Content 1',
          summary: 'Summary 1',
          memory_type: 'decision',
        },
        target: {
          id: 'mem2',
          content: 'Content 2',
          summary: 'Summary 2',
          memory_type: 'pattern',
        },
      },
    ];

    const result = await classifyEdges(pairs, 'sk-ant-test');

    expect(result).toEqual([
      {
        source_id: 'mem1',
        target_id: 'mem2',
        relation_type: 'refines',
        strength: 0.9,
      },
    ]);
  });

  it('filters out invalid classifications', async () => {
    const responseText = JSON.stringify([
      {
        source_id: 'mem1',
        target_id: 'mem2',
        relation_type: 'relates_to',
        strength: 0.8,
      },
      {
        // Invalid: missing relation_type
        source_id: 'mem3',
        target_id: 'mem4',
        strength: 0.7,
      },
      {
        // Invalid: invalid relation_type
        source_id: 'mem5',
        target_id: 'mem6',
        relation_type: 'invalid_type',
        strength: 0.6,
      },
      {
        // Invalid: strength out of range
        source_id: 'mem7',
        target_id: 'mem8',
        relation_type: 'derived_from',
        strength: 1.5,
      },
    ]);

    mockCreate.mockResolvedValue({
      content: [
        {
          type: 'text',
          text: responseText,
        },
      ],
    });

    const pairs: MemoryPair[] = [
      {
        source: {
          id: 'mem1',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'decision',
        },
        target: {
          id: 'mem2',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'pattern',
        },
      },
    ];

    const result = await classifyEdges(pairs, 'sk-ant-test');

    // Only first classification is valid
    expect(result).toEqual([
      {
        source_id: 'mem1',
        target_id: 'mem2',
        relation_type: 'relates_to',
        strength: 0.8,
      },
    ]);
  });

  it('returns empty array on parse failure', async () => {
    mockCreate.mockResolvedValue({
      content: [
        {
          type: 'text',
          text: 'invalid json',
        },
      ],
    });

    const pairs: MemoryPair[] = [
      {
        source: {
          id: 'mem1',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'decision',
        },
        target: {
          id: 'mem2',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'pattern',
        },
      },
    ];

    const result = await classifyEdges(pairs, 'sk-ant-test');

    expect(result).toEqual([]);
  });

  it('returns empty array when response is not an array', async () => {
    mockCreate.mockResolvedValue({
      content: [
        {
          type: 'text',
          text: JSON.stringify({ error: 'not an array' }),
        },
      ],
    });

    const pairs: MemoryPair[] = [
      {
        source: {
          id: 'mem1',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'decision',
        },
        target: {
          id: 'mem2',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'pattern',
        },
      },
    ];

    const result = await classifyEdges(pairs, 'sk-ant-test');

    expect(result).toEqual([]);
  });

  it('throws error when no text content in response', async () => {
    mockCreate.mockResolvedValue({
      content: [],
    });

    const pairs: MemoryPair[] = [
      {
        source: {
          id: 'mem1',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'decision',
        },
        target: {
          id: 'mem2',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'pattern',
        },
      },
    ];

    await expect(classifyEdges(pairs, 'sk-ant-test')).rejects.toThrow(
      'No text content in Haiku response'
    );
  });

  it('throws error with context when API call fails', async () => {
    mockCreate.mockRejectedValue(
      new Error('Network timeout')
    );

    const pairs: MemoryPair[] = [
      {
        source: {
          id: 'mem1',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'decision',
        },
        target: {
          id: 'mem2',
          content: 'Content',
          summary: 'Summary',
          memory_type: 'pattern',
        },
      },
    ];

    await expect(classifyEdges(pairs, 'sk-ant-test')).rejects.toThrow(
      'Haiku edge classification failed: Network timeout'
    );
  });

  it('validates all edge relation types', async () => {
    const responseText = JSON.stringify([
      { source_id: '1', target_id: '2', relation_type: 'relates_to', strength: 0.8 },
      { source_id: '1', target_id: '3', relation_type: 'derived_from', strength: 0.8 },
      { source_id: '1', target_id: '4', relation_type: 'contradicts', strength: 0.8 },
      { source_id: '1', target_id: '5', relation_type: 'exemplifies', strength: 0.8 },
      { source_id: '1', target_id: '6', relation_type: 'refines', strength: 0.8 },
      { source_id: '1', target_id: '7', relation_type: 'supersedes', strength: 0.8 },
      { source_id: '1', target_id: '8', relation_type: 'source_of', strength: 0.8 },
    ]);

    mockCreate.mockResolvedValue({
      content: [{ type: 'text', text: responseText }],
    });

    const pairs: MemoryPair[] = [
      {
        source: { id: '1', content: 'C', summary: 'S', memory_type: 'decision' },
        target: { id: '2', content: 'C', summary: 'S', memory_type: 'pattern' },
      },
    ];

    const result = await classifyEdges(pairs, 'sk-ant-test');

    expect(result).toHaveLength(7);
    expect(result.map((r) => r.relation_type)).toEqual([
      'relates_to',
      'derived_from',
      'contradicts',
      'exemplifies',
      'refines',
      'supersedes',
      'source_of',
    ]);
  });
});
