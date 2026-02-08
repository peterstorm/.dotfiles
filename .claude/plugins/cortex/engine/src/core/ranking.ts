// Minimal inline types for ranking engine
// These align with types.ts from T1 (running in parallel)

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
  readonly confidence: number;      // 0-1
  readonly priority: number;        // 1-10
  readonly source_context: string;  // JSON: { branch, commits, files }
  readonly access_count: number;
  readonly centrality?: number;     // In-degree count, added by caller if available
}

interface SearchResult {
  readonly memory: Memory;
  readonly score: number;
  readonly source: 'project' | 'global';
}

// Per-category line budgets (FR-016)
const CATEGORY_BUDGETS: Record<MemoryType, number> = {
  architecture: 25,
  decision: 25,
  pattern: 25,
  gotcha: 20,
  progress: 30,
  context: 15,
  code_description: 10,
  code: 0  // Raw code not included in push surface
};

// FR-015: Composite ranking formula
// rank = (confidence * 0.5) + (priority/10 * 0.2) + (centrality * 0.15) + (log(access+1)/maxLog * 0.15)
export function computeRank(
  memory: Memory,
  options: {
    readonly maxAccessLog: number;
    readonly currentBranch?: string;
    readonly branchBoost?: number;
  }
): number {
  const { maxAccessLog, currentBranch, branchBoost = 0.1 } = options;

  // Base score components
  const confidenceScore = memory.confidence * 0.5;
  const priorityScore = (memory.priority / 10) * 0.2;
  const centralityScore = (memory.centrality ?? 0) * 0.15;

  // Access frequency score (logarithmic)
  const accessLog = Math.log(memory.access_count + 1);
  const accessScore = maxAccessLog > 0 ? (accessLog / maxAccessLog) * 0.15 : 0;

  // Base rank
  let rank = confidenceScore + priorityScore + centralityScore + accessScore;

  // FR-018: Branch boost for memories tagged with current branch
  if (currentBranch) {
    try {
      const context = JSON.parse(memory.source_context);
      if (context.branch === currentBranch) {
        rank += branchBoost;
      }
    } catch {
      // Invalid JSON in source_context, no boost
    }
  }

  // Ensure rank is in [0, 1] range
  return Math.max(0, Math.min(1, rank));
}

// FR-016, FR-017, FR-018: Select memories for push surface with category budgets
export function selectForSurface(
  memories: readonly Memory[],
  options: {
    readonly currentBranch: string;
    readonly targetTokens?: number;
    readonly maxTokens?: number;
  }
): readonly Memory[] {
  const { currentBranch, targetTokens = 400, maxTokens = 550 } = options;

  // Filter out code type (not included in surface)
  const candidates = memories.filter(m => m.memory_type !== 'code');

  // Compute maxAccessLog for ranking
  const maxAccessLog = Math.max(
    ...candidates.map(m => Math.log(m.access_count + 1)),
    1  // Avoid division by zero
  );

  // Rank all candidates
  const ranked = candidates
    .map(memory => ({
      memory,
      rank: computeRank(memory, { maxAccessLog, currentBranch })
    }))
    .sort((a, b) => b.rank - a.rank);

  // Category budget tracking
  const categoryUsed: Record<MemoryType, number> = {
    architecture: 0,
    decision: 0,
    pattern: 0,
    gotcha: 0,
    context: 0,
    progress: 0,
    code_description: 0,
    code: 0
  };

  const selected: Memory[] = [];
  let totalTokens = 0;

  // First pass: select within soft budgets
  for (const { memory } of ranked) {
    const type = memory.memory_type;
    const budget = CATEGORY_BUDGETS[type];
    const lines = estimateLines(memory.summary);

    // Skip if budget exhausted (soft limit)
    if (categoryUsed[type] >= budget) {
      continue;
    }

    // Skip if would exceed max tokens
    const tokens = estimateTokens(memory.summary);
    if (totalTokens + tokens > maxTokens) {
      break;
    }

    selected.push(memory);
    categoryUsed[type] += lines;
    totalTokens += tokens;

    // Stop if we hit target
    if (totalTokens >= targetTokens) {
      break;
    }
  }

  // FR-017: Allow overflow for high-value memories if under target
  if (totalTokens < targetTokens) {
    for (const { memory } of ranked) {
      if (selected.includes(memory)) continue;

      const tokens = estimateTokens(memory.summary);
      if (totalTokens + tokens > maxTokens) {
        break;
      }

      selected.push(memory);
      totalTokens += tokens;

      if (totalTokens >= targetTokens) {
        break;
      }
    }
  }

  return selected;
}

// FR-015: Merge project and global search results, deduplicate, re-rank
export function mergeResults(
  projectResults: readonly SearchResult[],
  globalResults: readonly SearchResult[],
  limit: number
): readonly SearchResult[] {
  // Deduplicate by memory ID (project takes precedence)
  const seen = new Set<string>();
  const merged: SearchResult[] = [];

  // Add project results first
  for (const result of projectResults) {
    if (!seen.has(result.memory.id)) {
      seen.add(result.memory.id);
      merged.push(result);
    }
  }

  // Add global results if not seen
  for (const result of globalResults) {
    if (!seen.has(result.memory.id)) {
      seen.add(result.memory.id);
      merged.push(result);
    }
  }

  // Sort by score descending
  merged.sort((a, b) => b.score - a.score);

  // Return top N
  return merged.slice(0, limit);
}

// Helper: estimate tokens (word-based approximation)
// Rough heuristic: 1 token ≈ 0.75 words
function estimateTokens(text: string): number {
  const words = text.trim().split(/\s+/).length;
  return Math.ceil(words * 0.75);
}

// Helper: estimate lines (newline count + 1)
function estimateLines(text: string): number {
  return text.split('\n').length;
}
