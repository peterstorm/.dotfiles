// Extract: turn a transcript chunk into memories and entity facts.
//
// The recorded prompt is replayed verbatim: it is built from a transcript
// window, not from data that can be re-rendered. Comparing two extractions is a
// soft match: each reference memory is paired with at most one arm memory by
// token overlap of summary and content. This is a proxy for fact-level recall
// and precision; the report says so and lists the unmatched memories for hand
// review.

export type ExtractedMemory = Readonly<{
  summary: string;
  content: string;
  memory_type: string;
  scope: string;
}>;

export type Extraction = Readonly<{ memories: readonly ExtractedMemory[]; entities: number }>;

/** Minimum token-set Jaccard for two memories to count as the same fact (calibrate by hand review). */
export const MATCH_THRESHOLD = 0.2;

const STOPWORDS = new Set(
  'a an and are as at be by for from has have in is it its of on or that the this to was were with not no but can will'.split(' '),
);

export const tokens = (text: string): ReadonlySet<string> =>
  new Set(
    text
      .toLowerCase()
      .split(/[^a-z0-9æøå_.-]+/)
      .map((t) => t.replace(/^[.-]+|[.-]+$/g, ''))
      .filter((t) => t.length > 1 && !STOPWORDS.has(t)),
  );

export const jaccard = (a: ReadonlySet<string>, b: ReadonlySet<string>): number => {
  if (a.size === 0 && b.size === 0) return 0;
  let shared = 0;
  for (const t of a) if (b.has(t)) shared += 1;
  return shared / (a.size + b.size - shared);
};

export type ExtractionMatch = Readonly<{
  referenceCount: number;
  armCount: number;
  matched: number;
  /** Matched pairs whose memory_type agrees. */
  sameType: number;
  unmatchedReference: readonly ExtractedMemory[];
  unmatchedArm: readonly ExtractedMemory[];
}>;

/**
 * Greedy one-to-one matching, best similarity first. Greedy is not the optimal
 * assignment, but with a threshold and short lists the difference is noise next
 * to the proxy's own error.
 */
export const matchExtractions = (reference: Extraction, arm: Extraction): ExtractionMatch => {
  const refTokens = reference.memories.map((m) => tokens(`${m.summary} ${m.content}`));
  const armTokens = arm.memories.map((m) => tokens(`${m.summary} ${m.content}`));
  const candidates: { r: number; a: number; score: number }[] = [];
  refTokens.forEach((rt, r) =>
    armTokens.forEach((at, a) => {
      const score = jaccard(rt, at);
      if (score >= MATCH_THRESHOLD) candidates.push({ r, a, score });
    }),
  );
  candidates.sort((x, y) => y.score - x.score || x.r - y.r || x.a - y.a);
  const usedR = new Set<number>();
  const usedA = new Set<number>();
  let sameType = 0;
  for (const { r, a } of candidates) {
    if (usedR.has(r) || usedA.has(a)) continue;
    usedR.add(r);
    usedA.add(a);
    if (reference.memories[r]?.memory_type === arm.memories[a]?.memory_type) sameType += 1;
  }
  return {
    referenceCount: reference.memories.length,
    armCount: arm.memories.length,
    matched: usedR.size,
    sameType,
    unmatchedReference: reference.memories.filter((_, i) => !usedR.has(i)),
    unmatchedArm: arm.memories.filter((_, i) => !usedA.has(i)),
  };
};
