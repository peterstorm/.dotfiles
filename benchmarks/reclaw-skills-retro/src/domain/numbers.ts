// Number grounding: is every figure in the delivered message something the
// model could have read, rather than something it made up?
//
// A figure is grounded when one of its readings equals one of the evidence's
// readings. Readings absorb formatting, not arithmetic: Danish and English
// separators (`1.234,50` / `1,234.50`), trailing zeros (`9,00` = `9`) and
// rounding (evidence `62.47` grounds `62.5` and `62`). Derived values — a
// seconds-to-hours conversion, a difference, a percentage — are reported as
// ungrounded; the grading threshold tolerates a few of them.

/** Figures this small are counts and list markers; grounding them proves nothing. */
const MIN_SIGNIFICANT = 10;

const DATE = /\b\d{4}-\d{2}-\d{2}(?:T[\d:.]+Z?)?\b/g;
const TIME = /\b\d{1,2}:\d{2}(?::\d{2})?\b/g;
const URL = /\bhttps?:\/\/\S+/g;
const NUMBER = /\d+(?:[.,]\d+)*/g;

const canonical = (n: number): string => String(Number(n.toFixed(6)));

/** Every value a written figure could mean, as canonical decimal strings. */
export const readings = (token: string): ReadonlySet<string> => {
  const out = new Set<string>();
  const add = (s: string): void => {
    const n = Number(s);
    if (Number.isFinite(n)) out.add(canonical(n));
  };
  const separators = token.match(/[.,]/g) ?? [];
  if (separators.length === 0) {
    add(token);
    return out;
  }
  const last = Math.max(token.lastIndexOf('.'), token.lastIndexOf(','));
  const intPart = token.slice(0, last).replace(/[.,]/g, '');
  const tail = token.slice(last + 1);
  // The last separator as a decimal point: 1.234,50 → 1234.50, 9,00 → 9.
  add(`${intPart}.${tail}`);
  // Every separator as a thousands grouping: 1,234 → 1234, 1.234.567 → 1234567.
  if (tail.length === 3) add(token.replace(/[.,]/g, ''));
  return out;
};

const scrub = (text: string): string => text.replace(URL, ' ').replace(DATE, ' ').replace(TIME, ' ');

/** The significant figures written in a text, as raw tokens. */
export const figures = (text: string): readonly string[] =>
  (scrub(text).match(NUMBER) ?? []).filter((t) => [...readings(t)].some((r) => Math.abs(Number(r)) >= MIN_SIGNIFICANT));

/**
 * Everything the evidence can ground: each figure's readings, scaled by the
 * skill's unit factors (øre → kroner is 0.01), and their roundings. A comma
 * run is also read piece by piece, because JSON and CSV lists (`19.3,20.3`)
 * use the comma as a delimiter, not a separator.
 */
export const evidenceIndex = (texts: readonly string[], scales: readonly number[] = [1]): ReadonlySet<string> => {
  const index = new Set<string>();
  const add = (n: number): void => {
    for (const places of [0, 1, 2]) index.add(canonical(Number(n.toFixed(places))));
    index.add(canonical(n));
  };
  for (const text of texts) {
    for (const token of text.match(NUMBER) ?? []) {
      const pieces = token.includes(',') ? [token, ...token.split(',')] : [token];
      for (const piece of pieces) {
        for (const r of readings(piece)) for (const s of scales) add(Number(r) * s);
      }
    }
  }
  return index;
};

export type Grounding = Readonly<{ total: number; ungrounded: readonly string[] }>;

export const ground = (output: string, evidence: ReadonlySet<string>): Grounding => {
  const tokens = figures(output);
  return {
    total: tokens.length,
    ungrounded: tokens.filter((t) => ![...readings(t)].some((r) => evidence.has(r))),
  };
};
