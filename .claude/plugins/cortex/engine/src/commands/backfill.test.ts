/**
 * Tests for backfill command
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { openDatabase, insertMemory } from '../infra/db.ts';
import { backfill } from './backfill.ts';
import { createMemory } from '../core/types.ts';

// Create mock functions
const mockIsGeminiAvailable = vi.fn();
const mockEmbedTexts = vi.fn();
const mockEnsureModelLoaded = vi.fn();
const mockEmbedLocal = vi.fn();

// Mock the embedding modules
vi.mock('../infra/gemini-embed.ts', () => ({
  isGeminiAvailable: mockIsGeminiAvailable,
  embedTexts: mockEmbedTexts,
  MAX_BATCH_SIZE: 20,
  EMBEDDING_DIMENSIONS: 768,
}));

vi.mock('../infra/local-embed.ts', () => ({
  ensureModelLoaded: mockEnsureModelLoaded,
  embedLocal: mockEmbedLocal,
}));

describe('backfill', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('when no memories need backfilling', () => {
    it('returns zero processed and failed', async () => {
      const db = openDatabase(':memory:');

      // Insert memory with gemini embedding
      const memory = createMemory({
        id: 'mem-1',
        content: 'Test content',
        summary: 'Test summary',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.8,
        priority: 5,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
        embedding: new Float64Array(768),
      });

      insertMemory(db, memory);

      const result = await backfill(db, 'test-project', 'fake-api-key');

      expect(result).toEqual({
        ok: true,
        processed: 0,
        failed: 0,
        errors: [],
        method: 'gemini',
      });
    });

    it('returns zero when database is empty', async () => {
      const db = openDatabase(':memory:');

      const result = await backfill(db, 'test-project', 'fake-api-key');

      expect(result).toEqual({
        ok: true,
        processed: 0,
        failed: 0,
        errors: [],
        method: 'gemini',
      });
    });
  });

  describe('when Gemini API is available', () => {
    it('processes memories via Gemini and updates embeddings', async () => {
      const db = openDatabase(':memory:');

      // Setup mocks
      mockIsGeminiAvailable.mockReturnValue(true);
      mockEmbedTexts.mockResolvedValue([
        new Float64Array(768).fill(0.5),
        new Float64Array(768).fill(0.7),
      ]);

      // Insert memories without embeddings
      const memory1 = createMemory({
        id: 'mem-1',
        content: 'Decision about architecture',
        summary: 'Chose microservices',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.9,
        priority: 8,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      const memory2 = createMemory({
        id: 'mem-2',
        content: 'Pattern for error handling',
        summary: 'Use Either type',
        memory_type: 'pattern',
        scope: 'global',
        confidence: 0.85,
        priority: 7,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      insertMemory(db, memory1);
      insertMemory(db, memory2);

      const result = await backfill(db, 'test-project', 'fake-api-key');

      expect(result).toEqual({
        ok: true,
        processed: 2,
        failed: 0,
        errors: [],
        method: 'gemini',
      });

      expect(mockIsGeminiAvailable).toHaveBeenCalledWith('fake-api-key');
      expect(mockEmbedTexts).toHaveBeenCalledWith(
        [
          '[decision] [project:test-project] Chose microservices',
          '[pattern] [project:test-project] Use Either type',
        ],
        'fake-api-key'
      );
    });

    it('batches large sets of memories', async () => {
      const db = openDatabase(':memory:');

      // Setup mocks
      mockIsGeminiAvailable.mockReturnValue(true);

      // Create 25 memories (exceeds batch size of 20)
      const memories = Array.from({ length: 25 }, (_, i) =>
        createMemory({
          id: `mem-${i}`,
          content: `Content ${i}`,
          summary: `Summary ${i}`,
          memory_type: 'context',
          scope: 'project',
          confidence: 0.7,
          priority: 5,
          source_type: 'extraction',
          source_session: 'session-1',
          source_context: JSON.stringify({ branch: 'main' }),
        })
      );

      memories.forEach((m) => insertMemory(db, m));

      // Mock embedTexts to return appropriate size arrays
      mockEmbedTexts
        .mockResolvedValueOnce(
          Array.from({ length: 20 }, () => new Float64Array(768))
        )
        .mockResolvedValueOnce(
          Array.from({ length: 5 }, () => new Float64Array(768))
        );

      const result = await backfill(db, 'test-project', 'fake-api-key');

      expect(result).toEqual({
        ok: true,
        processed: 25,
        failed: 0,
        errors: [],
        method: 'gemini',
      });

      // Should have called embedTexts twice (two batches)
      expect(mockEmbedTexts).toHaveBeenCalledTimes(2);
    });

    it('handles batch API failures gracefully', async () => {
      const db = openDatabase(':memory:');

      // Setup mocks - simulate API failure
      mockIsGeminiAvailable.mockReturnValue(true);
      mockEmbedTexts.mockRejectedValueOnce(new Error('API error'));

      // Insert memory
      const memory = createMemory({
        id: 'mem-1',
        content: 'First memory',
        summary: 'First',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.9,
        priority: 8,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      insertMemory(db, memory);

      const result = await backfill(db, 'test-project', 'fake-api-key');

      // API failure means 0 processed, 1 failed
      expect(result.ok).toBe(true);
      if (result.ok) {
        expect(result.processed).toBe(0);
        expect(result.failed).toBe(1);
        expect(result.method).toBe('gemini');
        expect(result.errors.length).toBeGreaterThan(0);
        expect(result.errors[0]).toContain('Failed to embed batch');
      }
    });
  });

  describe('when Gemini API is unavailable', () => {
    it('falls back to local embeddings', async () => {
      const db = openDatabase(':memory:');

      // Setup mocks
      mockIsGeminiAvailable.mockReturnValue(false);
      mockEnsureModelLoaded.mockResolvedValue(true);
      mockEmbedLocal
        .mockResolvedValueOnce(new Float32Array(384).fill(0.3))
        .mockResolvedValueOnce(new Float32Array(384).fill(0.4));

      // Insert memories without embeddings
      const memory1 = createMemory({
        id: 'mem-1',
        content: 'Decision about architecture',
        summary: 'Chose microservices',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.9,
        priority: 8,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      const memory2 = createMemory({
        id: 'mem-2',
        content: 'Pattern for error handling',
        summary: 'Use Either type',
        memory_type: 'pattern',
        scope: 'global',
        confidence: 0.85,
        priority: 7,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      insertMemory(db, memory1);
      insertMemory(db, memory2);

      const result = await backfill(db, 'test-project');

      expect(result).toEqual({
        ok: true,
        processed: 2,
        failed: 0,
        errors: [],
        method: 'local',
      });

      expect(mockEnsureModelLoaded).toHaveBeenCalled();
      expect(mockEmbedLocal).toHaveBeenCalledTimes(2);
      expect(mockEmbedLocal).toHaveBeenCalledWith(
        '[decision] [project:test-project] Chose microservices'
      );
      expect(mockEmbedLocal).toHaveBeenCalledWith(
        '[pattern] [project:test-project] Use Either type'
      );
    });

    it('handles local model unavailable', async () => {
      const db = openDatabase(':memory:');

      // Setup mocks
      mockIsGeminiAvailable.mockReturnValue(false);
      mockEnsureModelLoaded.mockResolvedValue(false);

      // Insert memory without embeddings
      const memory = createMemory({
        id: 'mem-1',
        content: 'Decision about architecture',
        summary: 'Chose microservices',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.9,
        priority: 8,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      insertMemory(db, memory);

      const result = await backfill(db, 'test-project');

      expect(result.ok).toBe(true);
      if (result.ok) {
        expect(result.processed).toBe(0);
        expect(result.failed).toBe(1);
        expect(result.method).toBe('local');
        expect(result.errors.length).toBeGreaterThan(0);
        expect(result.errors[0]).toContain('Local model failed to load');
      }
    });

    it('handles individual local embedding failures', async () => {
      const db = openDatabase(':memory:');

      // Setup mocks
      mockIsGeminiAvailable.mockReturnValue(false);
      mockEnsureModelLoaded.mockResolvedValue(true);
      mockEmbedLocal
        .mockResolvedValueOnce(new Float32Array(384).fill(0.3))
        .mockRejectedValueOnce(new Error('Model error'));

      // Insert memories
      const memory1 = createMemory({
        id: 'mem-1',
        content: 'First memory',
        summary: 'First',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.9,
        priority: 8,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      const memory2 = createMemory({
        id: 'mem-2',
        content: 'Second memory',
        summary: 'Second',
        memory_type: 'pattern',
        scope: 'project',
        confidence: 0.8,
        priority: 7,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      insertMemory(db, memory1);
      insertMemory(db, memory2);

      const result = await backfill(db, 'test-project');

      expect(result.ok).toBe(true);
      if (result.ok) {
        expect(result.processed).toBe(1);
        expect(result.failed).toBe(1);
        expect(result.method).toBe('local');
        expect(result.errors.length).toBeGreaterThan(0);
        expect(result.errors[0]).toContain('Failed to embed/update memory');
      }
    });
  });

  describe('edge cases', () => {
    it('only processes memories with both embeddings null', async () => {
      const db = openDatabase(':memory:');

      // Setup mocks
      mockIsGeminiAvailable.mockReturnValue(true);
      mockEmbedTexts.mockResolvedValue([
        new Float64Array(768).fill(0.5),
      ]);

      // Insert memories with different embedding states
      const memoryNoEmbeddings = createMemory({
        id: 'mem-no-embed',
        content: 'No embeddings',
        summary: 'No embeddings',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.9,
        priority: 8,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });

      const memoryWithGemini = createMemory({
        id: 'mem-with-gemini',
        content: 'Has gemini embedding',
        summary: 'Has gemini',
        memory_type: 'pattern',
        scope: 'project',
        confidence: 0.8,
        priority: 7,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
        embedding: new Float64Array(768),
      });

      const memoryWithLocal = createMemory({
        id: 'mem-with-local',
        content: 'Has local embedding',
        summary: 'Has local',
        memory_type: 'gotcha',
        scope: 'project',
        confidence: 0.7,
        priority: 6,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
        local_embedding: new Float32Array(384),
      });

      insertMemory(db, memoryNoEmbeddings);
      insertMemory(db, memoryWithGemini);
      insertMemory(db, memoryWithLocal);

      const result = await backfill(db, 'test-project', 'fake-api-key');

      expect(result).toEqual({
        ok: true,
        processed: 1,
        failed: 0,
        errors: [],
        method: 'gemini',
      });

      // Should only process the one without embeddings
      expect(mockEmbedTexts).toHaveBeenCalledTimes(1);
      expect(mockEmbedTexts).toHaveBeenCalledWith(
        ['[decision] [project:test-project] No embeddings'],
        'fake-api-key'
      );
    });

    it('handles unexpected errors gracefully', async () => {
      const db = openDatabase(':memory:');

      // Insert memory to ensure we reach the isGeminiAvailable call
      const memory = createMemory({
        id: 'mem-1',
        content: 'Test content',
        summary: 'Test summary',
        memory_type: 'decision',
        scope: 'project',
        confidence: 0.9,
        priority: 8,
        source_type: 'extraction',
        source_session: 'session-1',
        source_context: JSON.stringify({ branch: 'main' }),
      });
      insertMemory(db, memory);

      // Setup mocks - simulate catastrophic failure
      mockIsGeminiAvailable.mockImplementation(() => {
        throw new Error('Unexpected error');
      });

      const result = await backfill(db, 'test-project', 'fake-api-key');

      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.error).toContain('Backfill failed');
      }
    });
  });
});
