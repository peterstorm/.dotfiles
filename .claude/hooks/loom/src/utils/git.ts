/**
 * Git utilities — pure functions for test counting, thin wrappers for I/O
 * Uses execSync for vitest compatibility (no bun shell dependency)
 */

import { execSync } from "node:child_process";

function exec(cmd: string): string {
  try {
    return execSync(cmd, { encoding: "utf-8", stdio: ["pipe", "pipe", "pipe"] });
  } catch {
    return "";
  }
}

/** Get current HEAD SHA */
export function headSha(): string | null {
  const result = exec("git rev-parse HEAD").trim();
  return result || null;
}

/** Check if in a git repo */
export function isGitRepo(): boolean {
  try {
    execSync("git rev-parse --git-dir", { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/** Get default branch name */
export function defaultBranch(): string {
  const ref = exec("git symbolic-ref refs/remotes/origin/HEAD").trim();
  return ref.replace(/^refs\/remotes\/origin\//, "") || "main";
}

/** Get merge base between HEAD and default branch */
export function mergeBase(branch: string): string | null {
  const result = exec(`git merge-base HEAD "origin/${branch}"`).trim();
  return result || null;
}

/** Get git diff between two refs */
export function diff(from?: string, to?: string): string {
  if (from && to) return exec(`git diff ${from} ${to}`);
  if (from) return exec(`git diff ${from}`);
  return exec("git diff");
}

/** Get staged diff */
export function diffStaged(): string {
  return exec("git diff --cached");
}

/** Diff specific files (unstaged) */
export function diffFiles(files: string[]): string {
  if (files.length === 0) return "";
  const quoted = files.map(f => `"${f}"`).join(" ");
  return exec(`git diff -- ${quoted}`);
}

/** Diff specific files (staged) */
export function diffFilesStaged(files: string[]): string {
  if (files.length === 0) return "";
  const quoted = files.map(f => `"${f}"`).join(" ");
  return exec(`git diff --cached -- ${quoted}`);
}

/** Check if file is tracked by git */
export function isTracked(file: string): boolean {
  try {
    execSync(`git ls-files --error-unmatch "${file}"`, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/** Diff untracked file against /dev/null */
export function diffUntracked(file: string): string {
  try {
    return execSync(`git diff --no-index /dev/null "${file}"`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (e: unknown) {
    // git diff --no-index exits 1 when files differ (always for new files)
    if (e && typeof e === "object" && "stdout" in e) {
      return String((e as { stdout: unknown }).stdout ?? "");
    }
    return "";
  }
}

// --- Pure functions for test evidence (no git calls) ---

export interface TestCount {
  java: number;
  ts: number;
  python: number;
  total: number;
}

/** Count new test methods in a diff string (pure) */
export function countNewTests(diffContent: string): TestCount {
  const lines = diffContent.split("\n");
  let java = 0;
  let ts = 0;
  let python = 0;

  for (const line of lines) {
    if (!line.startsWith("+")) continue;
    if (/@(Test|Property|ParameterizedTest)\b/.test(line)) java++;
    if (/\s(it|test|describe)\(/.test(line)) ts++;
    if (/(def test_|class Test)/.test(line)) python++;
  }

  return { java, ts, python, total: java + ts + python };
}

/** Count assertions in a diff string (pure) */
export function countAssertions(diffContent: string): number {
  const lines = diffContent.split("\n");
  let count = 0;

  for (const line of lines) {
    if (!line.startsWith("+")) continue;
    // Match at most one per line to avoid cross-language double-counting
    if (/(assertThat|assertEquals|assertNotNull|assertThrows|verify\()/.test(line)) { count++; continue; }
    if (/(expect\(|toEqual|toBe|toHaveBeenCalled|toThrow|\.should\.)/.test(line)) { count++; continue; }
    if (/(assert\w*\(|assert [^=]|self\.assert|pytest\.raises)/.test(line)) { count++; continue; }
  }

  return count;
}
