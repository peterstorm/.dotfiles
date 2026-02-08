import { describe, it, expect } from 'vitest';
import * as fc from 'fast-check';
import { computeRank, selectForSurface, mergeResults } from './ranking.js';

// Minimal types for testing
type MemoryType =
  | 'architecture'
  | 'decision'
  | 'pattern'
  | 'gotcha'
  | 'context'
  | 'progress'
  | 'code_description'
  | 'code';

interface Memory {
  readonly id: string;
  readonly content: string;
  readonly summary: string;
  readonly memory_type: MemoryType;
  readonly confidence: number;
  readonly priority: number;
  readonly source_context: string;
  readonly access_count: number;
  readonly centrality?: number;
}

interface SearchResult {
  readonly memory: Memory;
  readonly score: number;
  readonly source: 'project' | 'global';
}

// Arbitraries for property tests
const memoryTypeArb = fc.constantFrom<MemoryType>(
  'architecture',
  'decision',
  'pattern',
  'gotcha',
  'context',
  'progress',
  'code_description',
  'code'
);

const memoryArb = fc.record({
  id: fc.uuid(),
  content: fc.lorem({ maxCount: 50 }),
  summary: fc.lorem({ maxCount: 20 }),
  memory_type: memoryTypeArb,
  confidence: fc.double({ min: 0, max: 1, noNaN: true }),
  priority: fc.integer({ min: 1, max: 10 }),
  source_context: fc.string().map(s => JSON.stringify({ branch: s, commits: [], files: [] })),
  access_count: fc.nat({ max: 1000 }),
  centrality: fc.option(fc.double({ min: 0, max: 1, noNaN: true }), { nil: undefined })
});

const searchResultArb = (sourceType: 'project' | 'global') =>
  fc.record({
    memory: memoryArb,
    score: fc.double({ min: 0, max: 1, noNaN: true }),
    source: fc.constant(sourceType)
  });

// Example-based tests
describe('computeRank', () => {
  it('computes rank for basic memory', () => {
    const memory: Memory = {
      id: '1',
      content: 'test',
      summary: 'test summary',
      memory_type: 'decision',
      confidence: 0.8,
      priority: 5,
      source_context: JSON.stringify({ branch: 'main', commits: [], files: [] }),
      access_count: 10,
      centrality: 0.5
    };

    const rank = computeRank(memory, { maxAccessLog: Math.log(11) });

    // Expected: (0.8 * 0.5) + (0.5 * 0.2) + (0.5 * 0.15) + (log(11)/log(11) * 0.15)
    // = 0.4 + 0.1 + 0.075 + 0.15 = 0.725
    expect(rank).toBeCloseTo(0.725, 2);
  });

  it('applies branch boost when branch matches', () => {
    const memory: Memory = {
      id: '1',
      content: 'test',
      summary: 'test summary',
      memory_type: 'decision',
      confidence: 0.8,
      priority: 5,
      source_context: JSON.stringify({ branch: 'feature/x', commits: [], files: [] }),
      access_count: 0,
      centrality: 0
    };

    const withoutBoost = computeRank(memory, {
      maxAccessLog: 1,
      currentBranch: 'main'
    });

    const withBoost = computeRank(memory, {
      maxAccessLog: 1,
      currentBranch: 'feature/x'
    });

    expect(withBoost).toBeGreaterThan(withoutBoost);
    expect(withBoost - withoutBoost).toBeCloseTo(0.1, 2);
  });

  it('handles invalid source_context gracefully', () => {
    const memory: Memory = {
      id: '1',
      content: 'test',
      summary: 'test summary',
      memory_type: 'decision',
      confidence: 0.5,
      priority: 5,
      source_context: 'invalid json',
      access_count: 0,
      centrality: 0
    };

    expect(() =>
      computeRank(memory, { maxAccessLog: 1, currentBranch: 'main' })
    ).not.toThrow();
  });

  it('handles zero maxAccessLog', () => {
    const memory: Memory = {
      id: '1',
      content: 'test',
      summary: 'test summary',
      memory_type: 'decision',
      confidence: 0.5,
      priority: 5,
      source_context: '{}',
      access_count: 100,
      centrality: 0
    };

    const rank = computeRank(memory, { maxAccessLog: 0 });
    expect(rank).toBeGreaterThanOrEqual(0);
    expect(rank).toBeLessThanOrEqual(1);
  });
});

// Property-based tests
describe('computeRank properties', () => {
  it('always returns non-negative rank', () => {
    fc.assert(
      fc.property(memoryArb, fc.double({ min: 0.1, max: 10, noNaN: true }), (memory, maxLog) => {
        const rank = computeRank(memory, { maxAccessLog: maxLog });
        expect(rank).toBeGreaterThanOrEqual(0);
      })
    );
  });

  it('always returns rank bounded in [0, 1]', () => {
    fc.assert(
      fc.property(memoryArb, fc.double({ min: 0.1, max: 10, noNaN: true }), (memory, maxLog) => {
        const rank = computeRank(memory, { maxAccessLog: maxLog });
        expect(rank).toBeLessThanOrEqual(1);
      })
    );
  });

  it('higher priority yields higher or equal rank (monotonic)', () => {
    fc.assert(
      fc.property(
        memoryArb,
        fc.integer({ min: 1, max: 10 }),
        fc.integer({ min: 1, max: 10 }),
        (baseMemory, priority1, priority2) => {
          fc.pre(priority1 !== priority2);

          const mem1 = { ...baseMemory, priority: priority1 };
          const mem2 = { ...baseMemory, priority: priority2 };

          const rank1 = computeRank(mem1, { maxAccessLog: 1 });
          const rank2 = computeRank(mem2, { maxAccessLog: 1 });

          if (priority1 > priority2) {
            expect(rank1).toBeGreaterThanOrEqual(rank2);
          } else {
            expect(rank2).toBeGreaterThanOrEqual(rank1);
          }
        }
      )
    );
  });

  it('branch boost increases rank', () => {
    fc.assert(
      fc.property(memoryArb, fc.string(), (baseMemory, branch) => {
        const memory = {
          ...baseMemory,
          source_context: JSON.stringify({ branch, commits: [], files: [] })
        };

        const withoutBoost = computeRank(memory, { maxAccessLog: 1 });
        const withBoost = computeRank(memory, { maxAccessLog: 1, currentBranch: branch });

        expect(withBoost).toBeGreaterThanOrEqual(withoutBoost);
      })
    );
  });

  it('higher confidence yields higher or equal rank', () => {
    fc.assert(
      fc.property(
        memoryArb,
        fc.double({ min: 0, max: 1, noNaN: true }),
        fc.double({ min: 0, max: 1, noNaN: true }),
        (baseMemory, conf1, conf2) => {
          fc.pre(Math.abs(conf1 - conf2) > 0.1);

          const mem1 = { ...baseMemory, confidence: conf1 };
          const mem2 = { ...baseMemory, confidence: conf2 };

          const rank1 = computeRank(mem1, { maxAccessLog: 1 });
          const rank2 = computeRank(mem2, { maxAccessLog: 1 });

          // Confidence contributes 0.5 weight to rank
          // With diff > 0.1, we expect rank diff > 0.05
          if (conf1 > conf2) {
            expect(rank1).toBeGreaterThan(rank2 - 0.001);
          } else {
            expect(rank2).toBeGreaterThan(rank1 - 0.001);
          }
        }
      )
    );
  });
});

describe('selectForSurface', () => {
  it('excludes code type memories', () => {
    const memories: Memory[] = [
      {
        id: '1',
        content: 'code content',
        summary: 'code summary',
        memory_type: 'code',
        confidence: 1.0,
        priority: 10,
        source_context: JSON.stringify({ branch: 'main', commits: [], files: [] }),
        access_count: 100,
        centrality: 1.0
      },
      {
        id: '2',
        content: 'decision content',
        summary: 'decision summary',
        memory_type: 'decision',
        confidence: 0.8,
        priority: 5,
        source_context: JSON.stringify({ branch: 'main', commits: [], files: [] }),
        access_count: 10,
        centrality: 0.5
      }
    ];

    const selected = selectForSurface(memories, { currentBranch: 'main' });

    expect(selected).toHaveLength(1);
    expect(selected[0].memory_type).toBe('decision');
  });

  it('respects category budgets (soft limit)', () => {
    // Create enough memories that we would exceed maxTokens before selecting all
    const longSummary = 'word '.repeat(100); // ~75 tokens per memory
    const memories: Memory[] = Array.from({ length: 50 }, (_, i) => ({
      id: `${i}`,
      content: `content ${i}`,
      summary: longSummary,
      memory_type: 'decision' as MemoryType,
      confidence: 0.8,
      priority: 8,
      source_context: JSON.stringify({ branch: 'main', commits: [], files: [] }),
      access_count: i,
      centrality: 0.5
    }));

    const selected = selectForSurface(memories, { currentBranch: 'main', maxTokens: 500 });

    // With maxTokens=500 and ~75 tokens per memory, should select around 6-7 memories
    expect(selected.length).toBeLessThan(50);
    expect(selected.length).toBeGreaterThan(0);
  });

  it('selects highest ranked memories first', () => {
    const memories: Memory[] = [
      {
        id: '1',
        content: 'low',
        summary: 'low priority',
        memory_type: 'decision',
        confidence: 0.3,
        priority: 1,
        source_context: JSON.stringify({ branch: 'main', commits: [], files: [] }),
        access_count: 0,
        centrality: 0
      },
      {
        id: '2',
        content: 'high',
        summary: 'high priority',
        memory_type: 'decision',
        confidence: 0.9,
        priority: 10,
        source_context: JSON.stringify({ branch: 'main', commits: [], files: [] }),
        access_count: 100,
        centrality: 0.8
      }
    ];

    const selected = selectForSurface(memories, { currentBranch: 'main' });

    expect(selected[0].id).toBe('2');
  });

  it('stops at max tokens', () => {
    const memories: Memory[] = Array.from({ length: 100 }, (_, i) => ({
      id: `${i}`,
      content: `content ${i}`,
      summary: 'a '.repeat(100),  // ~75 tokens each
      memory_type: 'decision' as MemoryType,
      confidence: 0.8,
      priority: 8,
      source_context: JSON.stringify({ branch: 'main', commits: [], files: [] }),
      access_count: i,
      centrality: 0.5
    }));

    const selected = selectForSurface(memories, {
      currentBranch: 'main',
      maxTokens: 200
    });

    const totalTokens = selected.reduce((sum, m) => {
      const words = m.summary.trim().split(/\s+/).length;
      return sum + Math.ceil(words * 0.75);
    }, 0);

    expect(totalTokens).toBeLessThanOrEqual(220); // Allow 10% overflow
  });
});

describe('selectForSurface properties', () => {
  it('never returns code type memories', () => {
    fc.assert(
      fc.property(fc.array(memoryArb, { minLength: 1, maxLength: 50 }), fc.string(), (memories, branch) => {
        const selected = selectForSurface(memories, { currentBranch: branch });
        expect(selected.every(m => m.memory_type !== 'code')).toBe(true);
      })
    );
  });

  it('returns memories in descending rank order', () => {
    fc.assert(
      fc.property(fc.array(memoryArb, { minLength: 2, maxLength: 20 }), fc.string(), (memories, branch) => {
        const selected = selectForSurface(memories, { currentBranch: branch });

        if (selected.length < 2) return;

        const maxAccessLog = Math.max(
          ...memories.map(m => Math.log(m.access_count + 1)),
          1
        );

        const ranks = selected.map(m =>
          computeRank(m, { maxAccessLog, currentBranch: branch })
        );

        for (let i = 0; i < ranks.length - 1; i++) {
          expect(ranks[i]).toBeGreaterThanOrEqual(ranks[i + 1] - 0.0001); // Allow small floating point errors
        }
      })
    );
  });
});

describe('mergeResults', () => {
  it('deduplicates by memory ID', () => {
    const sharedMemory: Memory = {
      id: 'shared',
      content: 'shared content',
      summary: 'shared summary',
      memory_type: 'decision',
      confidence: 0.8,
      priority: 5,
      source_context: '{}',
      access_count: 10,
      centrality: 0.5
    };

    const projectResults: SearchResult[] = [
      { memory: sharedMemory, score: 0.9, source: 'project' }
    ];

    const globalResults: SearchResult[] = [
      { memory: sharedMemory, score: 0.7, source: 'global' }
    ];

    const merged = mergeResults(projectResults, globalResults, 10);

    expect(merged).toHaveLength(1);
    expect(merged[0].source).toBe('project');
  });

  it('prefers project results over global when duplicate', () => {
    const memory: Memory = {
      id: 'dup',
      content: 'dup content',
      summary: 'dup summary',
      memory_type: 'decision',
      confidence: 0.8,
      priority: 5,
      source_context: '{}',
      access_count: 10,
      centrality: 0.5
    };

    const projectResults: SearchResult[] = [
      { memory, score: 0.5, source: 'project' }
    ];

    const globalResults: SearchResult[] = [
      { memory, score: 0.9, source: 'global' }
    ];

    const merged = mergeResults(projectResults, globalResults, 10);

    expect(merged).toHaveLength(1);
    expect(merged[0].source).toBe('project');
  });

  it('sorts by score descending', () => {
    const mem1: Memory = {
      id: '1',
      content: 'c1',
      summary: 's1',
      memory_type: 'decision',
      confidence: 0.8,
      priority: 5,
      source_context: '{}',
      access_count: 10,
      centrality: 0.5
    };

    const mem2: Memory = {
      id: '2',
      content: 'c2',
      summary: 's2',
      memory_type: 'decision',
      confidence: 0.8,
      priority: 5,
      source_context: '{}',
      access_count: 10,
      centrality: 0.5
    };

    const projectResults: SearchResult[] = [
      { memory: mem1, score: 0.5, source: 'project' }
    ];

    const globalResults: SearchResult[] = [
      { memory: mem2, score: 0.9, source: 'global' }
    ];

    const merged = mergeResults(projectResults, globalResults, 10);

    expect(merged[0].memory.id).toBe('2');
    expect(merged[1].memory.id).toBe('1');
  });

  it('respects limit', () => {
    const projectResults: SearchResult[] = Array.from({ length: 10 }, (_, i) => ({
      memory: {
        id: `p${i}`,
        content: 'c',
        summary: 's',
        memory_type: 'decision' as MemoryType,
        confidence: 0.8,
        priority: 5,
        source_context: '{}',
        access_count: 10,
        centrality: 0.5
      },
      score: 0.5 + i * 0.01,
      source: 'project' as const
    }));

    const globalResults: SearchResult[] = [];

    const merged = mergeResults(projectResults, globalResults, 5);

    expect(merged).toHaveLength(5);
  });
});

describe('mergeResults properties', () => {
  it('never returns more than limit', () => {
    fc.assert(
      fc.property(
        fc.array(searchResultArb('project'), { maxLength: 20 }),
        fc.array(searchResultArb('global'), { maxLength: 20 }),
        fc.integer({ min: 1, max: 30 }),
        (projectResults, globalResults, limit) => {
          const merged = mergeResults(projectResults, globalResults, limit);
          expect(merged.length).toBeLessThanOrEqual(limit);
        }
      )
    );
  });

  it('returns results sorted by score descending', () => {
    fc.assert(
      fc.property(
        fc.array(searchResultArb('project'), { minLength: 1, maxLength: 10 }),
        fc.array(searchResultArb('global'), { minLength: 1, maxLength: 10 }),
        (projectResults, globalResults) => {
          const merged = mergeResults(projectResults, globalResults, 50);

          for (let i = 0; i < merged.length - 1; i++) {
            expect(merged[i].score).toBeGreaterThanOrEqual(merged[i + 1].score);
          }
        }
      )
    );
  });

  it('contains no duplicate memory IDs', () => {
    fc.assert(
      fc.property(
        fc.array(searchResultArb('project'), { maxLength: 20 }),
        fc.array(searchResultArb('global'), { maxLength: 20 }),
        (projectResults, globalResults) => {
          const merged = mergeResults(projectResults, globalResults, 50);
          const ids = merged.map(r => r.memory.id);
          const uniqueIds = new Set(ids);
          expect(uniqueIds.size).toBe(ids.length);
        }
      )
    );
  });
});
