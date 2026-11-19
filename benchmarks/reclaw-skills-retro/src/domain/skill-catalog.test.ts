import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { SkillId } from './model.ts';
import { MIN_HITS, type SkillRevision, buildCatalog, classify } from './skill-catalog.ts';

const rev = (skill: string, lines: readonly string[], at = '2026-09-01', commit = `${skill}-${at}`): SkillRevision => ({
  skill: SkillId(skill),
  commit,
  committedAt: new Date(`${at}T00:00:00Z`),
  promptTemplate: lines.join('\n'),
  timeoutSec: 600,
});

const SHARED = ['{{personality}}', 'Today is {{dayOfWeek}}, {{date}}.', 'This line is shared boilerplate across skills.'];
const RUN_AT = new Date('2026-10-01T00:00:00Z');

/** Literal lines long enough to be signatures, distinct per skill by construction. */
const skillLines = (skill: string, n: number): readonly string[] =>
  Array.from({ length: n }, (_, i) => `Step ${i} of the ${skill} procedure does something specific.`);

const render = (template: string): string =>
  template.replace('{{personality}}', 'You are a personal AI assistant.').replace(/\{\{\w+\}\}/g, 'X');

describe('classify', () => {
  test('property: a rendered revision is attributed to its own skill, whatever wraps it', () => {
    fc.assert(
      fc.property(
        fc.uniqueArray(fc.stringMatching(/^[a-z]{3,10}$/), { minLength: 2, maxLength: 6 }),
        fc.integer({ min: MIN_HITS, max: 12 }),
        fc.nat(),
        fc.string(),
        (skills, n, pick, noise) => {
          const revisions = skills.map((s) => rev(s, [...SHARED, ...skillLines(s, n)]));
          const target = revisions[pick % revisions.length];
          if (target === undefined) return;
          const prompt = `${noise}\n${render(target.promptTemplate)}\n${noise}`;
          const c = classify(buildCatalog(revisions), prompt, RUN_AT);
          expect(c.kind === 'skill' && c.skill).toBe(target.skill);
        },
      ),
    );
  });

  test('lines shared by two skills are never signatures', () => {
    const catalog = buildCatalog([rev('a', [...SHARED, ...skillLines('a', 4)]), rev('b', [...SHARED, ...skillLines('b', 4)])]);
    expect(catalog.signatures.get(SkillId('a'))?.has('This line is shared boilerplate across skills.')).toBe(false);
  });

  test('a chat message with too little evidence is unclassified', () => {
    const catalog = buildCatalog([rev('a', skillLines('a', 5))]);
    const twoHits = skillLines('a', 2).join('\n');
    expect(classify(catalog, twoHits, RUN_AT)).toEqual({ kind: 'unclassified' });
    expect(classify(catalog, 'is the linting on?', RUN_AT)).toEqual({ kind: 'unclassified' });
  });

  test('a prompt carrying two skills evenly is ambiguous, not guessed', () => {
    const catalog = buildCatalog([rev('a', skillLines('a', 4)), rev('b', skillLines('b', 4))]);
    const c = classify(catalog, [...skillLines('a', 4), ...skillLines('b', 4)].join('\n'), RUN_AT);
    expect(c.kind).toBe('ambiguous');
  });

  test('the revision that ran is the one whose lines the prompt contains', () => {
    const old = rev('a', [...skillLines('a', 4), 'Old instruction that was later removed entirely.'], '2026-08-01', 'old');
    const neu = rev('a', [...skillLines('a', 4), 'New instruction that replaced the old one later.'], '2026-09-15', 'new');
    const catalog = buildCatalog([old, neu]);
    const prompt = render(old.promptTemplate);
    const c = classify(catalog, prompt, new Date('2026-10-01T00:00:00Z'));
    expect(c.kind === 'skill' && c.revision.commit).toBe('old');
  });

  test('on a tie the newest revision committed before the run wins', () => {
    const a1 = rev('a', skillLines('a', 4), '2026-08-01', 'first');
    const a2 = rev('a', skillLines('a', 4), '2026-09-01', 'second');
    const a3 = rev('a', skillLines('a', 4), '2026-11-01', 'after-run');
    const c = classify(buildCatalog([a1, a2, a3]), skillLines('a', 4).join('\n'), RUN_AT);
    expect(c.kind === 'skill' && c.revision.commit).toBe('second');
  });
});
