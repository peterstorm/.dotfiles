// Surface generator: generates push surface markdown from ranked memories
// Pure functional core - no I/O

import type { Memory, MemoryType } from './types.js';

// Per-category line budgets (FR-016)
export const CATEGORY_BUDGETS: Record<MemoryType, number> = {
  architecture: 25,
  decision: 25,
  pattern: 25,
  gotcha: 20,
  progress: 30,
  context: 15,
  code_description: 10,
  code: 0, // code blocks not included in surface (too large)
};

export interface SurfaceOptions {
  readonly maxTokens?: number; // default 500
  readonly allowOverflow?: boolean; // default true (FR-017)
}

export interface StalenessInfo {
  readonly stale: boolean;
  readonly age_hours: number;
}

/**
 * Generate push surface markdown from ranked memories.
 * Applies per-category line budgets with overflow and redistribution (FR-016, FR-017, FR-018).
 * Target 300-500 tokens (FR-025).
 */
export function generateSurface(
  memories: readonly Memory[],
  branch: string,
  staleness: StalenessInfo | null,
  options: SurfaceOptions = {}
): string {
  const maxTokens = options.maxTokens ?? 500;
  const allowOverflow = options.allowOverflow ?? true;

  if (memories.length === 0) {
    return '';
  }

  // Allocate memories to categories respecting budgets
  const allocated = allocateBudget(memories, CATEGORY_BUDGETS, allowOverflow);

  // Generate markdown sections
  const sections: string[] = [];

  // Header
  sections.push(`# Cortex Memory Surface`);
  sections.push('');
  sections.push(`**Branch:** ${branch}`);

  if (staleness && staleness.stale) {
    sections.push(`**Warning:** Surface is ${Math.round(staleness.age_hours)}h old. May be stale.`);
  }

  sections.push('');

  // Group by category and render
  const byCategory = groupByCategory(allocated);

  for (const [category, mems] of Object.entries(byCategory)) {
    if (mems.length === 0) continue;

    sections.push(`## ${capitalizeCategory(category)}`);
    sections.push('');

    for (const mem of mems) {
      sections.push(`- ${mem.summary}`);
      if (mem.tags.length > 0) {
        sections.push(`  *Tags: ${mem.tags.join(', ')}*`);
      }
    }

    sections.push('');
  }

  const content = sections.join('\n');

  // Token estimate check (informational)
  const tokens = estimateTokens(content);
  if (tokens > maxTokens * 1.1) {
    // Overflow beyond 10% - truncate
    return truncateToTokens(content, maxTokens);
  }

  return content;
}

/**
 * Allocate memories to categories respecting line budgets.
 * High-value memories can overflow (FR-017).
 * Under-budget categories redistribute (FR-018).
 */
export function allocateBudget(
  memories: readonly Memory[],
  budgets: Record<MemoryType, number>,
  allowOverflow: boolean
): readonly Memory[] {
  // Group by category
  const byCategory = groupByCategory(memories);

  const allocated: Memory[] = [];

  // First pass: allocate within budgets
  for (const [category, mems] of Object.entries(byCategory)) {
    const budget = budgets[category as MemoryType] ?? 0;
    if (budget === 0) continue; // skip code blocks

    const taken = mems.slice(0, budget);
    allocated.push(...taken);
  }

  if (!allowOverflow) {
    return allocated;
  }

  // Second pass: calculate unused budget (across ALL categories, not just those with memories)
  const unusedBudget = Object.entries(budgets).reduce((acc, [category, budget]) => {
    const mems = byCategory[category] ?? [];
    const used = Math.min(mems.length, budget);
    return acc + (budget - used);
  }, 0);

  if (unusedBudget === 0) {
    return allocated;
  }

  // Third pass: redistribute unused budget to high-value overflow memories
  const overflow: Memory[] = [];
  for (const [category, mems] of Object.entries(byCategory)) {
    const budget = budgets[category as MemoryType] ?? 0;
    if (mems.length > budget) {
      const extra = mems.slice(budget);
      overflow.push(...extra);
    }
  }

  // Sort overflow by rank (highest first) and take up to unused budget
  const sortedOverflow = [...overflow].sort((a, b) => (b.rank ?? 0) - (a.rank ?? 0));
  const redistributed = sortedOverflow.slice(0, unusedBudget);

  return [...allocated, ...redistributed];
}

/**
 * Wrap content in CORTEX_MEMORY markers (FR-024).
 */
export function wrapInMarkers(content: string): string {
  if (!content.trim()) {
    return '';
  }

  return `<!-- CORTEX_MEMORY_START -->
${content}
<!-- CORTEX_MEMORY_END -->`;
}

/**
 * Estimate token count using ~4 chars per token heuristic (FR-025).
 */
export function estimateTokens(text: string): number {
  // Simple heuristic: ~4 characters per token
  return Math.ceil(text.length / 4);
}

// Helper: group memories by category
function groupByCategory(memories: readonly Memory[]): Record<string, Memory[]> {
  const groups: Record<string, Memory[]> = {};

  for (const mem of memories) {
    if (!groups[mem.memory_type]) {
      groups[mem.memory_type] = [];
    }
    groups[mem.memory_type].push(mem);
  }

  return groups;
}

// Helper: capitalize category name for display
function capitalizeCategory(category: string): string {
  return category
    .split('_')
    .map(word => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');
}

// Helper: truncate content to token limit
function truncateToTokens(content: string, maxTokens: number): string {
  const maxChars = maxTokens * 4;
  if (content.length <= maxChars) {
    return content;
  }

  const truncated = content.slice(0, maxChars);
  const lastNewline = truncated.lastIndexOf('\n');

  return lastNewline > 0
    ? truncated.slice(0, lastNewline) + '\n\n*[Truncated to fit token budget]*'
    : truncated + '\n\n*[Truncated to fit token budget]*';
}
