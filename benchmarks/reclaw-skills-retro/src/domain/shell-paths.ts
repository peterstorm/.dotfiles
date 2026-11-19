// Which files a bash command writes or names, with relative paths resolved
// against the `cd` that precedes them in the same command line. Models often
// write `cd ~/dev/notes/…/fitness; cat > 2026/10/2026-10-23.md <<'E'`, and the
// target is only recognisable once joined to the directory.
//
// Deliberately syntactic: variables (`$NOTE`) and subshell tricks stay
// unresolved, so a write through them is reported as missing and goes to
// hand review rather than being guessed.

const CD = /\bcd\s+(['"]?)([^\s'";|&]+)\1/g;
const REDIRECT = /(?:^|[^\d&<>])>>?\s*(['"]?)([^\s'";|&<>]+)\1/g;
const TEE = /\btee\s+(?:-a\s+)?(['"]?)([^\s'";|&<>]+)\1/g;
const FILE_TOKEN = /[^\s'";|&<>()=]+\.(?:md|json|yaml|jsonl)\b/g;

type Located = Readonly<{ at: number; value: string }>;

const matches = (re: RegExp, text: string): readonly Located[] =>
  [...text.matchAll(re)].flatMap((m) => {
    const value = m[2] ?? m[0];
    return value.length > 0 ? [{ at: m.index + m[0].length - value.length, value }] : [];
  });

const HEREDOC_BODY = /(<<-?\s*(['"]?)(\w+)\2[^\n]*\n)[\s\S]*?\n\3(?=\n|$)/g;
/** A single-quoted string that is not itself a redirect target: an awk/jq program, a commit message. */
const QUOTED_PROGRAM = /(?<!>>?\s*)'[^'\n]*'/g;

/**
 * The command with heredoc bodies and quoted programs blanked: a note body's
 * `> quote` or awk's `$3 > 10` is text, not a redirect.
 */
const scannable = (command: string): string =>
  command.replace(HEREDOC_BODY, (_m, head: string) => `${head}\n`).replace(QUOTED_PROGRAM, "''");

const isAbsolute = (p: string): boolean => p.startsWith('/') || p.startsWith('~') || p.startsWith('$');

/** `p` as seen from the last `cd` before position `at`. */
const resolveAt = (cds: readonly Located[], p: Located): string => {
  if (isAbsolute(p.value)) return p.value;
  const dir = cds.filter((c) => c.at < p.at).at(-1);
  return dir === undefined ? p.value : `${dir.value.replace(/\/+$/, '')}/${p.value.replace(/^\.\//, '')}`;
};

/** Files the command writes through `>`, `>>` or `tee`. Descriptor redirects (`2>`, `&>`) are not writes. */
export const writeTargets = (raw: string): readonly string[] => {
  const command = scannable(raw);
  const cds = matches(CD, command);
  return [...matches(REDIRECT, command), ...matches(TEE, command)]
    .filter((t) => t.value !== '/dev/null' && !t.value.startsWith('&'))
    .map((t) => resolveAt(cds, t));
};

/** Every file-looking path the command names, resolved: what it read, listed or touched. */
export const namedFiles = (raw: string): readonly string[] => {
  const command = scannable(raw);
  const cds = matches(CD, command);
  return matches(FILE_TOKEN, command).map((t) => resolveAt(cds, { at: t.at, value: t.value }));
};
