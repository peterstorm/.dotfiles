/**
 * Core similarity functions for memory comparison
 * Pure functional implementations with no I/O
 */

/**
 * Discriminated union for similarity action classification
 */
export type SimilarityAction =
  | { type: 'ignore'; score: number }
  | { type: 'relate'; score: number }
  | { type: 'suggest'; score: number }
  | { type: 'consolidate'; score: number };

/**
 * Discriminated union for Jaccard pre-filter results
 */
export type JaccardPreFilter =
  | { result: 'definitely_similar'; score: number }
  | { result: 'definitely_different'; score: number }
  | { result: 'maybe'; score: number };

/**
 * Compute cosine similarity between two embedding vectors
 * Returns value in range [-1, 1] where 1 = identical, 0 = orthogonal, -1 = opposite
 *
 * @param a - First embedding vector
 * @param b - Second embedding vector
 * @returns Cosine similarity score
 */
export function cosineSimilarity(a: Float64Array, b: Float64Array): number {
  if (a.length !== b.length) {
    throw new Error(`Vector dimension mismatch: ${a.length} vs ${b.length}`);
  }
  if (a.length === 0) {
    throw new Error('Cannot compute similarity for empty vectors');
  }

  let dotProduct = 0;
  let magA = 0;
  let magB = 0;

  for (let i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    magA += a[i] * a[i];
    magB += b[i] * b[i];
  }

  const magnitude = Math.sqrt(magA) * Math.sqrt(magB);

  // Handle zero vectors
  if (magnitude === 0) {
    return 0;
  }

  return dotProduct / magnitude;
}

/**
 * Tokenize text into a set of normalized tokens
 * Lowercases, removes punctuation, splits on whitespace
 *
 * @param text - Input text to tokenize
 * @returns Set of normalized tokens
 */
export function tokenize(text: string): Set<string> {
  const normalized = text
    .toLowerCase()
    .replace(/[^\w\s]/g, ' ') // Replace punctuation with spaces
    .replace(/\s+/g, ' ')      // Collapse multiple spaces
    .trim();

  if (normalized === '') {
    return new Set();
  }

  return new Set(normalized.split(' '));
}

/**
 * Compute Jaccard similarity between two token sets
 * Returns value in range [0, 1] where 1 = identical sets, 0 = no overlap
 *
 * @param tokensA - First token set
 * @param tokensB - Second token set
 * @returns Jaccard similarity score
 */
export function jaccardSimilarity(tokensA: Set<string>, tokensB: Set<string>): number {
  if (tokensA.size === 0 && tokensB.size === 0) {
    return 1.0; // Both empty = identical
  }
  if (tokensA.size === 0 || tokensB.size === 0) {
    return 0.0; // One empty = no overlap
  }

  const intersection = new Set([...tokensA].filter(x => tokensB.has(x)));
  const union = new Set([...tokensA, ...tokensB]);

  return intersection.size / union.size;
}

/**
 * Classify similarity score into actionable categories
 * Based on FR-059:
 * - < 0.1: ignore (unrelated)
 * - 0.1-0.4: relate (create relates_to edge)
 * - 0.4-0.5: suggest (create suggested edge for review)
 * - > 0.5: consolidate (flag for merge)
 *
 * @param score - Similarity score in range [0, 1]
 * @returns Similarity action with type and original score
 */
export function classifySimilarity(score: number): SimilarityAction {
  if (score < 0.1) {
    return { type: 'ignore', score };
  }
  if (score < 0.4) {
    return { type: 'relate', score };
  }
  if (score <= 0.5) {
    return { type: 'suggest', score };
  }
  return { type: 'consolidate', score };
}

/**
 * Jaccard pre-filter to avoid expensive embedding similarity computation
 * Based on FR-060:
 * - > 0.6: definitely_similar (skip embedding check)
 * - < 0.1: definitely_different (skip embedding check)
 * - 0.1-0.6: maybe (proceed with embedding similarity)
 *
 * @param tokensNew - Tokens from new memory
 * @param tokensExisting - Tokens from existing memory
 * @returns Pre-filter result with classification and score
 */
export function jaccardPreFilter(
  tokensNew: Set<string>,
  tokensExisting: Set<string>
): JaccardPreFilter {
  const score = jaccardSimilarity(tokensNew, tokensExisting);

  if (score > 0.6) {
    return { result: 'definitely_similar', score };
  }
  if (score < 0.1) {
    return { result: 'definitely_different', score };
  }
  return { result: 'maybe', score };
}

/**
 * Batch similarity comparison result
 */
export type SimilarityResult = {
  targetIndex: number;
  score: number;
  action: SimilarityAction;
};

/**
 * Compare a single embedding against multiple target embeddings
 * Returns sorted results by similarity score (descending)
 *
 * @param query - Query embedding vector
 * @param targets - Array of target embedding vectors
 * @returns Array of similarity results sorted by score (highest first)
 */
export function batchCosineSimilarity(
  query: Float64Array,
  targets: Float64Array[]
): SimilarityResult[] {
  return targets
    .map((target, index) => {
      const score = cosineSimilarity(query, target);
      const action = classifySimilarity(score);
      return { targetIndex: index, score, action };
    })
    .sort((a, b) => b.score - a.score);
}
