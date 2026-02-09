import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import fc from 'fast-check';
import { embedTexts, isVoyageAvailable } from './voyage.js';

// Mock fetch globally
const originalFetch = global.fetch;

beforeEach(() => {
  global.fetch = vi.fn();
});

afterEach(() => {
  global.fetch = originalFetch;
  vi.restoreAllMocks();
});

describe('isVoyageAvailable', () => {
  it('returns true for valid non-empty API key', () => {
    expect(isVoyageAvailable('sk-test-key-123')).toBe(true);
  });

  it('returns false for undefined', () => {
    expect(isVoyageAvailable(undefined)).toBe(false);
  });

  it('returns false for empty string', () => {
    expect(isVoyageAvailable('')).toBe(false);
  });

  it('returns false for whitespace-only string', () => {
    expect(isVoyageAvailable('   ')).toBe(false);
  });

  it('returns false for non-string types', () => {
    expect(isVoyageAvailable(null as any)).toBe(false);
    expect(isVoyageAvailable(123 as any)).toBe(false);
    expect(isVoyageAvailable({} as any)).toBe(false);
    expect(isVoyageAvailable([] as any)).toBe(false);
  });
});

describe('embedTexts', () => {
  describe('successful embedding', () => {
    it('embeds single text successfully', async () => {
      const mockEmbedding = Array(1024).fill(0).map((_, i) => i * 0.001);
      const mockResponse = {
        data: [
          { embedding: mockEmbedding, index: 0 },
        ],
      };

      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => mockResponse,
      });

      const result = await embedTexts(['test text'], 'sk-test-key');

      expect(result).toHaveLength(1);
      expect(result[0]).toBeInstanceOf(Float64Array);
      expect(result[0].length).toBe(1024);
      expect(Array.from(result[0])).toEqual(mockEmbedding);

      // Verify fetch was called correctly
      expect(global.fetch).toHaveBeenCalledTimes(1);
      expect(global.fetch).toHaveBeenCalledWith(
        'https://api.voyageai.com/v1/embeddings',
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer sk-test-key',
          },
          body: JSON.stringify({
            model: 'voyage-3.5-lite',
            input: ['test text'],
            input_type: 'document',
          }),
        }
      );
    });

    it('embeds multiple texts in batch', async () => {
      const mockEmbeddings = [
        Array(1024).fill(0).map((_, i) => i * 0.001),
        Array(1024).fill(0).map((_, i) => i * 0.002),
        Array(1024).fill(0).map((_, i) => i * 0.003),
      ];
      const mockResponse = {
        data: [
          { embedding: mockEmbeddings[0], index: 0 },
          { embedding: mockEmbeddings[1], index: 1 },
          { embedding: mockEmbeddings[2], index: 2 },
        ],
      };

      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => mockResponse,
      });

      const texts = ['text one', 'text two', 'text three'];
      const result = await embedTexts(texts, 'sk-test-key');

      expect(result).toHaveLength(3);
      result.forEach((embedding, i) => {
        expect(embedding).toBeInstanceOf(Float64Array);
        expect(embedding.length).toBe(1024);
        expect(Array.from(embedding)).toEqual(mockEmbeddings[i]);
      });
    });

    it('handles out-of-order response indices correctly', async () => {
      const mockEmbeddings = [
        Array(1024).fill(0).map((_, i) => i * 0.001),
        Array(1024).fill(0).map((_, i) => i * 0.002),
      ];
      // API returns indices out of order
      const mockResponse = {
        data: [
          { embedding: mockEmbeddings[1], index: 1 },
          { embedding: mockEmbeddings[0], index: 0 },
        ],
      };

      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => mockResponse,
      });

      const result = await embedTexts(['text one', 'text two'], 'sk-test-key');

      // Should be sorted by index
      expect(result).toHaveLength(2);
      expect(Array.from(result[0])).toEqual(mockEmbeddings[0]);
      expect(Array.from(result[1])).toEqual(mockEmbeddings[1]);
    });

    it('returns empty array for empty input', async () => {
      const result = await embedTexts([], 'sk-test-key');
      expect(result).toEqual([]);
      expect(global.fetch).not.toHaveBeenCalled();
    });
  });

  describe('error handling', () => {
    it('throws on missing API key', async () => {
      await expect(embedTexts(['test'], '')).rejects.toThrow(
        'Voyage API key is required and must be non-empty'
      );
      expect(global.fetch).not.toHaveBeenCalled();
    });

    it('throws on undefined API key', async () => {
      await expect(embedTexts(['test'], undefined as any)).rejects.toThrow(
        'Voyage API key is required and must be non-empty'
      );
      expect(global.fetch).not.toHaveBeenCalled();
    });

    it('throws on network failure', async () => {
      (global.fetch as any).mockRejectedValueOnce(new Error('Network timeout'));

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Network failure calling Voyage API: Network timeout'
      );
    });

    it('throws on 401 authentication error', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: false,
        status: 401,
        statusText: 'Unauthorized',
        json: async () => ({ error: { message: 'Invalid API key' } }),
      });

      await expect(embedTexts(['test'], 'sk-invalid-key')).rejects.toThrow(
        'Voyage API authentication failed (401): Invalid API key'
      );
    });

    it('throws on 403 forbidden error', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: false,
        status: 403,
        statusText: 'Forbidden',
        json: async () => ({ message: 'Access denied' }),
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Voyage API authentication failed (403): Access denied'
      );
    });

    it('throws on 429 rate limit error', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: false,
        status: 429,
        statusText: 'Too Many Requests',
        json: async () => ({ error: { message: 'Rate limit exceeded' } }),
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Voyage API rate limit exceeded (429): Rate limit exceeded'
      );
    });

    it('throws on 500 server error', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: false,
        status: 500,
        statusText: 'Internal Server Error',
        json: async () => ({ error: { message: 'Server error' } }),
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Voyage API error (500): Server error'
      );
    });

    it('handles error response with no JSON body', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: false,
        status: 502,
        statusText: 'Bad Gateway',
        json: async () => {
          throw new Error('No JSON');
        },
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Voyage API error (502): Bad Gateway'
      );
    });

    it('throws on malformed JSON response', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => {
          throw new Error('Invalid JSON');
        },
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Malformed response from Voyage API: Invalid JSON'
      );
    });

    it('throws when response missing data field', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ model: 'voyage-3.5-lite' }),
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Malformed response from Voyage API: missing or invalid data field'
      );
    });

    it('throws when response data is not an array', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({ data: 'not an array' }),
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Malformed response from Voyage API: missing or invalid data field'
      );
    });

    it('throws when response has wrong number of embeddings', async () => {
      const mockEmbedding = Array(1024).fill(0);
      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          data: [{ embedding: mockEmbedding, index: 0 }],
        }),
      });

      await expect(embedTexts(['text1', 'text2'], 'sk-test-key')).rejects.toThrow(
        'Malformed response from Voyage API: expected 2 embeddings, got 1'
      );
    });

    it('throws when embedding is not an array', async () => {
      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          data: [{ embedding: 'not an array', index: 0 }],
        }),
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Failed to process embeddings: Malformed response: embedding is not an array'
      );
    });

    it('throws when embedding has wrong dimensions', async () => {
      const wrongDimensions = Array(512).fill(0); // Wrong size
      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          data: [{ embedding: wrongDimensions, index: 0 }],
        }),
      });

      await expect(embedTexts(['test'], 'sk-test-key')).rejects.toThrow(
        'Failed to process embeddings: Malformed response: expected 1024 dimensions, got 512'
      );
    });
  });

  describe('immutability', () => {
    it('accepts readonly array (immutability guarantee)', async () => {
      const mockEmbedding = Array(1024).fill(0);
      (global.fetch as any).mockResolvedValueOnce({
        ok: true,
        status: 200,
        json: async () => ({
          data: [{ embedding: mockEmbedding, index: 0 }],
        }),
      });

      const texts: readonly string[] = ['test text'];
      const result = await embedTexts(texts, 'sk-test-key');

      expect(result).toHaveLength(1);
      expect(result[0]).toBeInstanceOf(Float64Array);
    });
  });
});

// Property-based tests
describe('property tests', () => {
  describe('isVoyageAvailable invariants', () => {
    it('returns true only for non-empty strings', () => {
      fc.assert(
        fc.property(fc.anything(), (value) => {
          const result = isVoyageAvailable(value as any);
          if (typeof value === 'string' && value.trim().length > 0) {
            expect(result).toBe(true);
          } else {
            expect(result).toBe(false);
          }
        })
      );
    });

    it('is consistent for same input', () => {
      fc.assert(
        fc.property(fc.string(), (key) => {
          const result1 = isVoyageAvailable(key);
          const result2 = isVoyageAvailable(key);
          expect(result1).toBe(result2);
        })
      );
    });
  });

  describe('embedTexts output properties', () => {
    it('output array length matches input array length', async () => {
      await fc.assert(
        fc.asyncProperty(
          fc.array(fc.string({ minLength: 1, maxLength: 100 }), { minLength: 1, maxLength: 5 }),
          async (texts) => {
            const mockEmbeddings = texts.map(() => Array(1024).fill(0).map((_, i) => i * 0.001));
            const mockResponse = {
              data: texts.map((_, index) => ({
                embedding: mockEmbeddings[index],
                index,
              })),
            };

            (global.fetch as any).mockResolvedValueOnce({
              ok: true,
              status: 200,
              json: async () => mockResponse,
            });

            const result = await embedTexts(texts, 'sk-test-key');
            expect(result.length).toBe(texts.length);
          }
        ),
        { numRuns: 20 }
      );
    });

    it('all embeddings have correct dimensions', async () => {
      await fc.assert(
        fc.asyncProperty(
          fc.array(fc.string({ minLength: 1 }), { minLength: 1, maxLength: 3 }),
          async (texts) => {
            const mockEmbeddings = texts.map(() => Array(1024).fill(0).map((_, i) => i * 0.001));
            const mockResponse = {
              data: texts.map((_, index) => ({
                embedding: mockEmbeddings[index],
                index,
              })),
            };

            (global.fetch as any).mockResolvedValueOnce({
              ok: true,
              status: 200,
              json: async () => mockResponse,
            });

            const result = await embedTexts(texts, 'sk-test-key');
            result.forEach((embedding) => {
              expect(embedding).toBeInstanceOf(Float64Array);
              expect(embedding.length).toBe(1024);
            });
          }
        ),
        { numRuns: 10 }
      );
    });
  });
});
