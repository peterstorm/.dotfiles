// Every committed revision of every reclaw skill YAML, read from the reclaw git
// repository. Shell: spawns git, parses YAML (wire data) through zod.

import { parse as parseYaml } from 'yaml';
import { z } from 'zod';
import { SkillId } from '../domain/model.ts';
import type { SkillRevision } from '../domain/skill-catalog.ts';

const SKILLS_DIR = 'workspace/skills';

const skillYaml = z.object({
  promptTemplate: z.string().optional(),
  timeout: z.number().optional(),
});

const git = (repo: string, args: readonly string[]): string => {
  const proc = Bun.spawnSync(['git', '-C', repo, ...args], { stdout: 'pipe', stderr: 'pipe' });
  if (proc.exitCode !== 0) throw new Error(`git ${args.join(' ')} failed: ${proc.stderr.toString().trim()}`);
  return proc.stdout.toString();
};

/** A skill file is a YAML directly under the skills directory; subdirectories hold scripts and SKILL.md bundles. */
const isSkillFile = (path: string): boolean =>
  path.startsWith(`${SKILLS_DIR}/`) && path.endsWith('.yaml') && !path.slice(SKILLS_DIR.length + 1).includes('/');

export type HistoryLoad = Readonly<{ revisions: readonly SkillRevision[]; unreadable: readonly string[] }>;

export const loadSkillHistory = (repo: string): HistoryLoad => {
  const paths = [
    ...new Set(git(repo, ['log', '--format=', '--name-only', '--', SKILLS_DIR]).split('\n').filter(isSkillFile)),
  ].sort();
  const revisions: SkillRevision[] = [];
  const unreadable: string[] = [];
  for (const path of paths) {
    const skill = SkillId(path.slice(SKILLS_DIR.length + 1).replace(/\.yaml$/, ''));
    const commits = git(repo, ['log', '--format=%H%x09%cI', '--', path])
      .split('\n')
      .filter((l) => l.includes('\t'));
    for (const line of commits) {
      const [commit = '', committedAt = ''] = line.split('\t');
      const shown = Bun.spawnSync(['git', '-C', repo, 'show', `${commit}:${path}`], { stdout: 'pipe', stderr: 'pipe' });
      if (shown.exitCode !== 0) continue; // the commit deleted the file
      let raw: unknown;
      try {
        raw = parseYaml(shown.stdout.toString());
      } catch {
        unreadable.push(`${commit.slice(0, 8)}:${path}`);
        continue;
      }
      const parsed = skillYaml.safeParse(raw);
      if (!parsed.success) {
        unreadable.push(`${commit.slice(0, 8)}:${path}`);
        continue;
      }
      if (parsed.data.promptTemplate === undefined) continue; // a script skill: no prompt to match
      revisions.push({
        skill,
        commit,
        committedAt: new Date(committedAt),
        promptTemplate: parsed.data.promptTemplate,
        timeoutSec: parsed.data.timeout ?? null,
      });
    }
  }
  return { revisions, unreadable };
};
