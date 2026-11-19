// Reclaw's anomaly log (~/.cache/reclaw/skill-quality.jsonl): one line per
// suppressed or failed scheduled run, with the skill id reclaw itself knew.
// Shell: reads the file and parses each line through zod.

import { existsSync, readFileSync } from 'node:fs';
import { z } from 'zod';
import type { QualityLogEntry } from '../domain/crosscheck.ts';
import { SkillId } from '../domain/model.ts';

const lineSchema = z.object({
  timestamp: z.string(),
  skillId: z.string(),
  status: z.string(),
  durationMs: z.number().optional(),
});

export const loadQualityLog = (file: string): readonly QualityLogEntry[] => {
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8')
    .split('\n')
    .flatMap((line) => {
      if (line.trim().length === 0) return [];
      let raw: unknown;
      try {
        raw = JSON.parse(line);
      } catch {
        return [];
      }
      const parsed = lineSchema.safeParse(raw);
      return parsed.success
        ? [
            {
              at: new Date(parsed.data.timestamp),
              skill: SkillId(parsed.data.skillId),
              status: parsed.data.status,
              durationMs: parsed.data.durationMs ?? null,
            },
          ]
        : [];
    });
};
