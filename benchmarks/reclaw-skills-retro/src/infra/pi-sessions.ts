// Reading Pi session files. Shell: file-system access only; parsing is the core's.

import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export type SessionFile = Readonly<{ file: string; content: string }>;

/** Session files in a Pi session directory, oldest first (names start with the ISO start time). */
export const listSessionFiles = (dir: string): readonly string[] =>
  readdirSync(dir)
    .filter((f) => f.endsWith('.jsonl'))
    .sort()
    .map((f) => join(dir, f));

export const readSessionFile = (file: string): SessionFile => ({ file, content: readFileSync(file, 'utf8') });
