import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { namedFiles, writeTargets } from './shell-paths.ts';

const segment = fc.stringMatching(/^[a-z0-9-]{1,10}$/);

describe('writeTargets', () => {
  test('property: a relative redirect resolves against the cd before it', () => {
    fc.assert(
      fc.property(fc.array(segment, { minLength: 1, maxLength: 4 }), fc.array(segment, { minLength: 1, maxLength: 3 }), (dir, file) => {
        const d = `~/${dir.join('/')}`;
        const f = `${file.join('/')}.md`;
        expect(writeTargets(`cd ${d}; cat > ${f} <<'E'\nbody\nE`)).toEqual([`${d}/${f}`]);
      }),
    );
  });

  test('absolute targets are left alone; the latest cd wins', () => {
    expect(writeTargets('cd /a && echo x > /abs/f.md')).toEqual(['/abs/f.md']);
    expect(writeTargets('cd /a; cd /b; echo x >> f.md')).toEqual(['/b/f.md']);
    expect(writeTargets('echo x > f.md; cd /a')).toEqual(['f.md']);
  });

  test('descriptor redirects and /dev/null are not writes; tee is', () => {
    expect(writeTargets('bun g.ts > /tmp/g.json 2>/tmp/g.err; foo 2>&1 >/dev/null')).toEqual(['/tmp/g.json']);
    expect(writeTargets("cd ~/n; printf '%s' x | tee -a log/MOC.md")).toEqual(['~/n/log/MOC.md']);
  });

  test('quoted programs and heredoc bodies are text, not redirects', () => {
    expect(writeTargets("awk '$3 > 10 {print}' f.txt")).toEqual([]);
    expect(writeTargets("jq 'select(.n > 3)' a.json > out.json")).toEqual(['out.json']);
    expect(writeTargets("cat > note.md <<'E'\n> a quoted line\n> another\nE\necho done")).toEqual(['note.md']);
    expect(writeTargets("cd /v; echo x > 'q.md'")).toEqual(['/v/q.md']);
  });
});

describe('namedFiles', () => {
  test('resolves every file-looking token, read or written', () => {
    expect(namedFiles('cd ~/v/fitness; tail -2 2026/10/2026-10-23.md; cat /x/y.json')).toEqual([
      '~/v/fitness/2026/10/2026-10-23.md',
      '/x/y.json',
    ]);
  });
});
