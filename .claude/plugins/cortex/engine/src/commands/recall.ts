/**
 * Recall command - Semantic search via Voyage OR FTS5 fallback
 * Orchestrates search across project+global DBs, follows graph edges, updates access stats
 */

import type { Database } from 'bun:sqlite';
import type { SearchResult, Memory } from '../core/types.js';
import { isGeminiAvailable, embedTexts } from '../infra/gemini-embed.ts';
import {
  searchByEmbedding,
  searchByKeyword,
  getEdgesForMemory,
  getMemoriesByIds,
  updateMemory,
} from '../infra/db.js';
import { mergeResults } from '../core/ranking.js';
import { traverseGraph } from '../core/graph.js';

// Command options (validated externally)
export type RecallOptions = {
  readonly query: string; // Query text (required)
  readonly branch?: string; // Optional branch filter
  readonly limit?: number; // Default 10
  readonly keyword?: boolean; // Force keyword search (default false)
  readonly geminiApiKey?: string; // Gemini API key
};

// Command result
export type RecallResult = {
  readonly results: readonly SearchResult[];
  readonly method: 'semantic' | 'keyword';
};

// Error result (discriminated union)
export type RecallError =
  | { type: 'empty_query' }
  | { type: 'gemini_unavailable' }
  | { type: 'embedding_failed'; message: string }
  | { type: 'search_failed'; message: string };

/**
 * Parse query text with metadata prefix for embedding
 * Pure function - builds embedding text for semantic search
 */
function buildQueryEmbeddingText(query: string): string {
  // Query embeddings don't need memory_type or project prefix
  // Just return the query text as-is for semantic search
  return query.trim();
}

/**
 * Filter search results by branch
 * Pure function - filters memories based on source_context.branch
 */
function filterByBranch(
  results: readonly SearchResult[],
  branch: string
): readonly SearchResult[] {
  return results.filter((result) => {
    try {
      const context = JSON.parse(result.memory.source_context);
      return context.branch === branch;
    } catch {
      // Invalid JSON or missing branch, exclude
      return false;
    }
  });
}

/**
 * Follow source_of edges to get linked code blocks
 * I/O: Reads edges and memories from database
 */
function followSourceOfEdges(
  db: Database,
  memory: Memory
): readonly Memory[] {
  const edges = getEdgesForMemory(db, memory.id);

  // Find source_of edges pointing FROM this memory
  const sourceOfEdges = edges.filter(
    (edge) => edge.source_id === memory.id && edge.relation_type === 'source_of'
  );

  if (sourceOfEdges.length === 0) {
    return [];
  }

  // Get target memories (code blocks)
  const targetIds = sourceOfEdges.map((edge) => edge.target_id);
  return getMemoriesByIds(db, targetIds);
}

/**
 * Get related memories via graph traversal (depth 2)
 * Pure over edge data from I/O
 */
function getRelatedMemories(
  db: Database,
  memoryId: string
): readonly Memory[] {
  // I/O: Get ALL edges in the database (not just for this memory)
  const stmt = db.prepare('SELECT * FROM edges');
  const rows = stmt.all() as any[];

  const allEdges = rows.map(row => ({
    id: row.id,
    source_id: row.source_id,
    target_id: row.target_id,
    relation_type: row.relation_type,
    strength: row.strength,
    bidirectional: row.bidirectional === 1,
    status: row.status,
    created_at: row.created_at,
  }));

  // Pure: Traverse graph to depth 2
  const traversalResults = traverseGraph(memoryId, allEdges, {
    maxDepth: 2,
    direction: 'both',
  });

  // I/O: Batch-fetch discovered memories
  const memoryIds = traversalResults.map((result) => result.memoryId);
  if (memoryIds.length === 0) {
    return [];
  }

  return getMemoriesByIds(db, memoryIds);
}

/**
 * Update access statistics for retrieved memories (FR-037)
 * I/O: Writes to database
 */
function updateAccessStats(db: Database, memories: readonly Memory[]): void {
  const now = new Date().toISOString();

  for (const memory of memories) {
    updateMemory(db, memory.id, {
      access_count: memory.access_count + 1,
      last_accessed_at: now,
    });
  }
}

/**
 * Execute recall command
 * Imperative shell - orchestrates I/O with pure search logic
 *
 * @param projectDb - Project database instance
 * @param globalDb - Global database instance
 * @param options - Command options
 * @returns Either error or result
 */
export async function executeRecall(
  projectDb: Database,
  globalDb: Database,
  options: RecallOptions
):
  | Promise<{ success: true; result: RecallResult }>
  | Promise<{ success: false; error: RecallError }> {
  const query = options.query.trim();
  const limit = options.limit ?? 10;
  const forceKeyword = options.keyword ?? false;

  // Validate query
  if (query === '') {
    return Promise.resolve({
      success: false,
      error: { type: 'empty_query' },
    });
  }

  let projectResults: readonly Memory[];
  let globalResults: readonly Memory[];
  let searchMethod: 'semantic' | 'keyword';

  // Determine search method
  const useVoyage =
    !forceKeyword && isGeminiAvailable(options.geminiApiKey);

  if (useVoyage) {
    // Semantic search via Voyage
    try {
      // Build embedding text with metadata prefix
      const embeddingText = buildQueryEmbeddingText(query);

      // I/O: Embed query via Gemini
      const [queryEmbedding] = await embedTexts(
        [embeddingText],
        options.geminiApiKey!
      );

      // I/O: Search both databases
      projectResults = searchByEmbedding(projectDb, queryEmbedding, limit);
      globalResults = searchByEmbedding(globalDb, queryEmbedding, limit);

      searchMethod = 'semantic';
    } catch (error) {
      const message =
        error instanceof Error ? error.message : 'Unknown error';
      return Promise.resolve({
        success: false,
        error: { type: 'embedding_failed', message },
      });
    }
  } else {
    // Keyword search via FTS5 (fallback)
    try {
      projectResults = searchByKeyword(projectDb, query, limit);
      globalResults = searchByKeyword(globalDb, query, limit);
      searchMethod = 'keyword';
    } catch (error) {
      const message =
        error instanceof Error ? error.message : 'Unknown error';
      return Promise.resolve({
        success: false,
        error: { type: 'search_failed', message },
      });
    }
  }

  // Pure: Merge results from both databases
  const projectSearchResults: SearchResult[] = projectResults.map(
    (memory) => ({
      memory,
      score: 1.0, // Score not available from DB search
      source: 'project' as const,
      related: [],
    })
  );

  const globalSearchResults: SearchResult[] = globalResults.map((memory) => ({
    memory,
    score: 1.0,
    source: 'global' as const,
    related: [],
  }));

  let mergedResults = mergeResults(
    projectSearchResults,
    globalSearchResults,
    limit
  );

  // Optional branch filter
  if (options.branch) {
    mergedResults = filterByBranch(mergedResults, options.branch);
  }

  // For top results: follow source_of edges and get related memories
  const enrichedResults: SearchResult[] = [];

  for (const result of mergedResults) {
    const db = result.source === 'project' ? projectDb : globalDb;

    // Follow source_of edges to get linked code blocks
    const linkedCode = followSourceOfEdges(db, result.memory);

    // Get related memories via graph traversal (depth 2)
    const related = getRelatedMemories(db, result.memory.id);

    // Merge linked code and related (deduplicate by ID)
    const allRelated = new Map<string, Memory>();
    for (const mem of [...linkedCode, ...related]) {
      allRelated.set(mem.id, mem);
    }

    enrichedResults.push({
      ...result,
      related: Array.from(allRelated.values()),
    });
  }

  // Update access statistics for retrieved memories (FR-037)
  const projectMemories = enrichedResults
    .filter((r) => r.source === 'project')
    .map((r) => r.memory);
  const globalMemories = enrichedResults
    .filter((r) => r.source === 'global')
    .map((r) => r.memory);

  if (projectMemories.length > 0) {
    updateAccessStats(projectDb, projectMemories);
  }
  if (globalMemories.length > 0) {
    updateAccessStats(globalDb, globalMemories);
  }

  return Promise.resolve({
    success: true,
    result: {
      results: enrichedResults,
      method: searchMethod,
    },
  });
}

/**
 * Format recall result as JSON string
 * Pure function - formats data for output
 */
export function formatRecallResult(result: RecallResult): string {
  return JSON.stringify(result, null, 2);
}

/**
 * Format recall error as human-readable string
 * Pure function
 */
export function formatRecallError(error: RecallError): string {
  switch (error.type) {
    case 'empty_query':
      return 'Query text is required and must not be empty.';
    case 'gemini_unavailable':
      return 'Gemini API is unavailable. Use --keyword flag for FTS5 search.';
    case 'embedding_failed':
      return `Embedding failed: ${error.message}`;
    case 'search_failed':
      return `Search failed: ${error.message}`;
  }
}
