/**
 * Cross-platform file locking
 * Uses mkdir-based locking (atomic on all platforms)
 */

import { mkdirSync, rmSync, writeFileSync } from "node:fs";

const MAX_ATTEMPTS = 50;
const RETRY_MS = 100;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function acquireLock(lockFile: string): Promise<void> {
  const lockDir = `${lockFile}.lock`;

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    try {
      mkdirSync(lockDir);
      writeFileSync(`${lockDir}/pid`, `${process.pid}`);
      return;
    } catch {
      await sleep(RETRY_MS);
    }
  }

  throw new Error(`Could not acquire lock after ${MAX_ATTEMPTS} attempts: ${lockFile}`);
}

export function releaseLock(lockFile: string): void {
  try {
    rmSync(`${lockFile}.lock`, { recursive: true, force: true });
  } catch {
    // Ignore cleanup errors
  }
}

/** Run fn while holding lock, auto-release on completion or error */
export async function withLock<T>(lockFile: string, fn: () => T | Promise<T>): Promise<T> {
  await acquireLock(lockFile);
  try {
    return await fn();
  } finally {
    releaseLock(lockFile);
  }
}
