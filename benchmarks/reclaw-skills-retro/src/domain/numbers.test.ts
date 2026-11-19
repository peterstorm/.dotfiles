import { describe, expect, test } from 'bun:test';
import fc from 'fast-check';
import { evidenceIndex, figures, ground, readings } from './numbers.ts';

/** A value written the way a Danish or an English message would. */
const formats = (n: number): readonly string[] => {
  const [int = '0', frac] = n.toFixed(2).split('.');
  const grouped = (sep: string): string => int.replace(/\B(?=(\d{3})+(?!\d))/g, sep);
  return [`${grouped(',')}.${frac}`, `${grouped('.')},${frac}`, `${int}.${frac}`, `${int},${frac}`];
};

const money = fc.integer({ min: 1000, max: 99_999_999 }).map((c) => c / 100);

describe('number grounding', () => {
  test('property: a figure copied from the evidence is grounded in any locale format', () => {
    fc.assert(
      fc.property(money, fc.nat(3), (n, i) => {
        const written = formats(n)[i] ?? '';
        const g = ground(`Price now ${written} kr`, evidenceIndex([`{"price": ${n}}`]));
        expect(g.ungrounded).toEqual([]);
      }),
    );
  });

  test('property: rounding the evidence for display stays grounded', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1000, max: 999_999 }).map((x) => x / 1000), fc.constantFrom(0, 1, 2), (n, places) => {
        const shown = n.toFixed(places);
        if (Number(shown) < 10) return;
        expect(ground(`value ${shown}`, evidenceIndex([`v=${n}`])).ungrounded).toEqual([]);
      }),
    );
  });

  test('property: an invented figure absent from the evidence is ungrounded', () => {
    fc.assert(
      fc.property(fc.integer({ min: 10, max: 9999 }), fc.integer({ min: 10, max: 9999 }), (shown, known) => {
        fc.pre(shown !== known);
        const g = ground(`about ${shown} units`, evidenceIndex([`count ${known}`]));
        expect(g.ungrounded).toEqual([String(shown)]);
      }),
    );
  });

  test('JSON and CSV lists are read element by element', () => {
    const idx = evidenceIndex(['"temperature_2m":[19.3,20.3,21.0]']);
    expect(ground('07:00 19.3°C, 08:00 20.3°C', idx)).toEqual({ total: 2, ungrounded: [] });
  });

  test('unit scales ground converted values (øre → kroner)', () => {
    const text = 'Coke Zero now 17,00 kr';
    expect(ground(text, evidenceIndex(['{"price":1700}'])).ungrounded).toEqual(['17,00']);
    expect(ground(text, evidenceIndex(['{"price":1700}'], [1, 0.01])).ungrounded).toEqual([]);
  });

  test('dates, times, URLs and small counts are not figures', () => {
    expect(figures('On 2026-10-01 at 07:20 see https://x.io/item/123456 — 3 items')).toEqual([]);
  });

  test('readings: separators are ambiguous only when they can be', () => {
    expect([...readings('1,234')].sort()).toEqual(['1.234', '1234']);
    expect([...readings('9,00')]).toEqual(['9']);
    expect([...readings('1.234,50')]).toEqual(['1234.5']);
  });
});
