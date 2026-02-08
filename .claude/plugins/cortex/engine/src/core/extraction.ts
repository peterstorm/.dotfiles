/**
 * Pure functions for transcript extraction and parsing.
 * Implements FR-002, FR-004, FR-005, FR-006, FR-007, FR-008, FR-012, FR-108
 */

// Minimal inline types (no separate types file needed)
export type MemoryType =
  | "architecture"
  | "decision"
  | "pattern"
  | "gotcha"
  | "context"
  | "progress"
  | "code_description"
  | "code";

export type Category = "project" | "global";

export interface MemoryCandidate {
  readonly content: string;
  readonly summary: string;
  readonly memoryType: MemoryType;
  readonly category: Category;
  readonly confidence: number; // 0-1
  readonly priority: number; // 1-10
}

export interface TruncationResult {
  readonly truncated: string;
  readonly newCursor: number;
}

export interface GitContext {
  readonly branch: string;
  readonly projectName: string;
  readonly recentCommits?: readonly string[];
  readonly changedFiles?: readonly string[];
}

/**
 * Truncates transcript to maxBytes while preserving JSONL line boundaries.
 * Returns truncated content and new cursor position for resumable extraction.
 *
 * FR-004: Track cursor position for resumable extraction
 * FR-012: Transcript size threshold 100KB for resumable extraction
 *
 * @param content - JSONL transcript content
 * @param maxBytes - Maximum size in bytes (default 100KB per FR-012)
 * @param cursor - Optional starting position for resuming extraction
 * @returns Truncated content and new cursor position
 */
export function truncateTranscript(
  content: string,
  maxBytes: number = 100_000,
  cursor: number = 0
): TruncationResult {
  // Start from cursor position
  const remainingContent = content.slice(cursor);

  // If remaining content fits within maxBytes, return as-is
  const remainingBytes = Buffer.byteLength(remainingContent, "utf8");
  if (remainingBytes <= maxBytes) {
    return {
      truncated: remainingContent,
      newCursor: content.length, // End of content
    };
  }

  // Find the last complete line within maxBytes
  // Truncate to maxBytes first, then find last newline
  const truncatedBuffer = Buffer.from(remainingContent, "utf8").slice(
    0,
    maxBytes
  );
  const truncatedStr = truncatedBuffer.toString("utf8");

  // Find last newline to preserve JSONL boundary
  const lastNewline = truncatedStr.lastIndexOf("\n");

  if (lastNewline === -1) {
    // No newline found - return empty, cursor stays at current position
    return {
      truncated: "",
      newCursor: cursor,
    };
  }

  // Include the newline character
  const result = truncatedStr.slice(0, lastNewline + 1);
  const bytesConsumed = Buffer.byteLength(result, "utf8");

  return {
    truncated: result,
    newCursor: cursor + bytesConsumed,
  };
}

/**
 * Builds extraction prompt for LLM given transcript and git context.
 *
 * FR-002: Extract from JSONL transcript format
 * FR-005: Extract memory type (8 types)
 * FR-006: Extract confidence (0-1)
 * FR-007: Extract priority (1-10)
 * FR-008: Classify scope (project/global, >0.8 confidence = global)
 *
 * @param transcript - JSONL transcript content (possibly truncated)
 * @param gitContext - Git repository context
 * @returns Prompt string for LLM
 */
export function buildExtractionPrompt(
  transcript: string,
  gitContext: GitContext
): string {
  const { branch, projectName, recentCommits, changedFiles } = gitContext;

  const contextBlock = [
    `Project: ${projectName}`,
    `Branch: ${branch}`,
    recentCommits && recentCommits.length > 0
      ? `Recent commits:\n${recentCommits.map((c) => `  - ${c}`).join("\n")}`
      : null,
    changedFiles && changedFiles.length > 0
      ? `Changed files:\n${changedFiles.map((f) => `  - ${f}`).join("\n")}`
      : null,
  ]
    .filter(Boolean)
    .join("\n");

  return `Extract memories from this Claude Code session transcript.

Git Context:
${contextBlock}

Transcript (JSONL format):
${transcript}

Extract memories following these rules:

1. Memory Types (FR-005):
   - architecture: System design, structure, patterns
   - decision: Choices made with rationale
   - pattern: Reusable code/design patterns
   - gotcha: Pitfalls, edge cases, warnings
   - context: Background info, explanations
   - progress: Status updates, completed work
   - code_description: Prose explanation of code
   - code: Raw source code (paired with code_description)

2. Scope Classification (FR-008):
   - global: Reusable across projects (confidence >0.8 required)
   - project: Specific to this project (default)

3. Confidence (FR-006): 0-1 score based on clarity and relevance
   - High (0.8-1.0): Clear, actionable, well-explained
   - Medium (0.5-0.79): Useful but could be clearer
   - Low (0.3-0.49): Vague or context-dependent

4. Priority (FR-007): 1-10 score based on importance
   - Critical (9-10): Must-know information
   - High (7-8): Important decisions/patterns
   - Medium (4-6): Useful context/progress
   - Low (1-3): Minor details

Return JSON array of memories:
[
  {
    "content": "Full detailed content",
    "summary": "Concise 1-2 sentence summary",
    "memoryType": "decision",
    "category": "project",
    "confidence": 0.85,
    "priority": 8
  }
]

If no significant memories, return empty array [].`;
}

/**
 * Parses LLM extraction response into memory candidates.
 *
 * FR-005: Validate memory types
 * FR-006: Validate confidence range
 * FR-007: Validate priority range
 *
 * @param response - Raw LLM response text
 * @returns Array of validated memory candidates, or empty array on parse failure
 */
export function parseExtractionResponse(
  response: string
): readonly MemoryCandidate[] {
  try {
    // Extract JSON from response (handle markdown code blocks)
    const jsonMatch = response.match(/```json\s*([\s\S]*?)\s*```/) || [
      null,
      response,
    ];
    const jsonText = jsonMatch[1] || response;

    const parsed = JSON.parse(jsonText.trim());

    if (!Array.isArray(parsed)) {
      return [];
    }

    // Validate and filter candidates
    return parsed
      .filter(isValidCandidate)
      .map((c) => ({
        content: String(c.content),
        summary: String(c.summary),
        memoryType: c.memoryType as MemoryType,
        category: c.category as Category,
        confidence: Number(c.confidence),
        priority: Number(c.priority),
      }));
  } catch {
    // Parse failure - return empty array
    return [];
  }
}

/**
 * Validates a memory candidate object.
 */
function isValidCandidate(obj: unknown): obj is MemoryCandidate {
  if (typeof obj !== "object" || obj === null) return false;

  const candidate = obj as Record<string, unknown>;

  // Check required fields exist
  if (
    typeof candidate.content !== "string" ||
    typeof candidate.summary !== "string" ||
    typeof candidate.memoryType !== "string" ||
    typeof candidate.category !== "string" ||
    typeof candidate.confidence !== "number" ||
    typeof candidate.priority !== "number"
  ) {
    return false;
  }

  // Validate memory type (FR-005)
  const validTypes: readonly MemoryType[] = [
    "architecture",
    "decision",
    "pattern",
    "gotcha",
    "context",
    "progress",
    "code_description",
    "code",
  ];
  if (!validTypes.includes(candidate.memoryType as MemoryType)) {
    return false;
  }

  // Validate category
  if (candidate.category !== "project" && candidate.category !== "global") {
    return false;
  }

  // Validate confidence range (FR-006)
  if (candidate.confidence < 0 || candidate.confidence > 1) {
    return false;
  }

  // Validate priority range (FR-007)
  if (
    candidate.priority < 1 ||
    candidate.priority > 10 ||
    !Number.isInteger(candidate.priority)
  ) {
    return false;
  }

  return true;
}

/**
 * Builds embedding text with metadata prefix for semantic search.
 *
 * FR-108: Embedding metadata prefix: '[memory_type] [project:name] summary content'
 *
 * @param memory - Memory candidate with type and content
 * @param projectName - Project name for prefix
 * @returns Formatted text for embedding
 */
export function buildEmbeddingText(
  memory: MemoryCandidate,
  projectName: string
): string {
  return `[${memory.memoryType}] [project:${projectName}] ${memory.summary}`;
}
