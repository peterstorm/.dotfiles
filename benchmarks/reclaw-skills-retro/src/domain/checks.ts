// Deterministic graders. Reliability (did the run complete?) and quality (was a
// completed run correct?) are kept apart: a run that never reached the model is
// an availability fact about the serving box, not evidence about the model.
//
// Quality checks run only on completed runs (delivered or ALL_CLEAR). Each
// returns a Verdict; `n/a` means the check does not apply to this run, which is
// different from passing it.

import { type Run, type SkillId, assertNever, durationMs } from './model.ts';
import { evidenceIndex, ground } from './numbers.ts';
import { namedFiles, writeTargets } from './shell-paths.ts';
import type { SkillRevision } from './skill-catalog.ts';

export type Verdict = Readonly<
  | { check: string; status: 'pass' }
  | { check: string; status: 'fail'; detail: string }
  | { check: string; status: 'n/a' }
>;

/**
 * Checks that measure a signal rather than prove a defect: number grounding
 * cannot tell a currency conversion from an invented price, and the
 * absent-user regex reads prose. Their failures go to hand review and never
 * decide whether a run is clean.
 */
export const HEURISTIC_CHECKS: ReadonlySet<string> = new Set(['numbers-grounded', 'no-question-to-absent-user']);

export const isHardFailure = (v: Verdict): boolean => v.status === 'fail' && !HEURISTIC_CHECKS.has(v.check);

const pass = (check: string): Verdict => ({ check, status: 'pass' });
const fail = (check: string, detail: string): Verdict => ({ check, status: 'fail', detail });
const notApplicable = (check: string): Verdict => ({ check, status: 'n/a' });

/**
 * When a requirement binds a run. Skill prompts changed during the period under
 * review, so a clause is enforced only if the prompt that actually ran (its
 * matched revision) contains it — never by calendar date.
 */
export type Applicability =
  | Readonly<{ kind: 'prompt-says'; text: string }>
  /** For evening skills whose step is "if tomorrow is a weekday". Days are Europe/Copenhagen. */
  | Readonly<{ kind: 'tomorrow-is-weekday' }>;

/** What a skill's own YAML promises, beyond the rules every skill shares. */
export type Requirement = Readonly<
  { label: string; when?: readonly Applicability[] } & (
    | { kind: 'command'; pattern: RegExp }
    /** `noOp`: on an ALL_CLEAR run, reading the target (it already existed) satisfies the requirement. */
    | { kind: 'vault-write'; path: RegExp; noOp: 'read-counts' | 'must-write' }
    | { kind: 'output-matches'; pattern: RegExp; min: number }
    | { kind: 'max-lines'; max: number }
  )
>;

export type SkillContract = Readonly<{
  skill: SkillId;
  /** Whether the skill defines a nothing-to-report condition at all. */
  allClear: 'allowed' | 'forbidden';
  /** Unit factors between what tools return and what the message states (øre → kroner: 0.01). */
  numberScales: readonly number[];
  requirements: readonly Requirement[];
}>;

// ─── Thresholds (calibrated by hand review 2026-11-19; change only with a new review) ──

/** A completed message may carry this many figures the evidence cannot ground… */
const MAX_UNGROUNDED = 3;
/** …or this share of its figures, whichever is more lenient. */
const MAX_UNGROUNDED_SHARE = 0.2;
const REVIEW_TIME_ZONE = 'Europe/Copenhagen';

// ─── Universal checks ────────────────────────────────────────────────────────

const deliveredText = (run: Run): string | undefined =>
  run.outcome.kind === 'delivered' ? run.outcome.text : undefined;

/** A line that is the sentinel once markdown decoration is stripped: `ALL_CLEAR`, **ALL_CLEAR**, `- ALL_CLEAR`. */
const isSentinelLine = (line: string): boolean => line.replace(/[`*_>#\-\s[\]]/g, '') === 'ALLCLEAR';

/**
 * The run meant "nothing to report", whether or not the sentinel survived
 * reclaw's exact match. A decorated sentinel is graded once, by sentinel-exact,
 * not again by every check that treats all-clear runs differently.
 */
const signalsAllClear = (run: Run): boolean => {
  const text = deliveredText(run);
  return run.outcome.kind === 'all-clear' || (text !== undefined && text.split('\n').some(isSentinelLine));
};

/**
 * The model meant "nothing to report" but wrapped the sentinel in narration or
 * markdown, so reclaw's exact-match suppression missed and the user was paged.
 * A message that merely mentions the word in prose is not a failed sentinel.
 */
const sentinelExact = (run: Run): Verdict => {
  const text = deliveredText(run);
  if (text === undefined) return pass('sentinel-exact');
  return signalsAllClear(run)
    ? fail('sentinel-exact', `decorated or accompanied ALL_CLEAR in a ${text.length}-char message`)
    : pass('sentinel-exact');
};

const LEAKED_MARKUP = /<\/?think>|<\/?tool_call>|<\|[a-z_]+\|>|\[TOOL_CALLS\]|"toolCall"/i;

/** Reasoning or tool-call syntax that escaped into the user-facing message. */
const noLeakedMarkup = (run: Run): Verdict => {
  const text = deliveredText(run);
  if (text === undefined) return notApplicable('no-leaked-markup');
  const hit = text.match(LEAKED_MARKUP);
  return hit === null ? pass('no-leaked-markup') : fail('no-leaked-markup', `contains ${hit[0]}`);
};

const ASKS_ABSENT_USER =
  /\b(?:would you like me to|shall i\b|do you want me to|should i (?:go ahead|proceed)|want me to (?:go ahead|proceed))/i;

/** The scheduled preamble says nobody is there to answer. Heuristic; review its fails. */
const noQuestionToAbsentUser = (run: Run): Verdict => {
  const text = deliveredText(run);
  if (text === undefined) return notApplicable('no-question-to-absent-user');
  const hit = text.match(ASKS_ABSENT_USER);
  return hit === null ? pass('no-question-to-absent-user') : fail('no-question-to-absent-user', `"${hit[0]}"`);
};

const notTruncated = (run: Run): Verdict =>
  run.outcome.kind === 'delivered' && run.outcome.truncated
    ? fail('not-truncated', 'final message stopped on the output-length cap')
    : pass('not-truncated');

const withinTimeout = (run: Run, revision: SkillRevision): Verdict => {
  if (revision.timeoutSec === null) return notApplicable('within-timeout');
  const ms = durationMs(run);
  return ms <= revision.timeoutSec * 1000
    ? pass('within-timeout')
    : fail('within-timeout', `${Math.round(ms / 1000)} s against a ${revision.timeoutSec} s timeout`);
};

const numbersGrounded = (run: Run, scales: readonly number[]): Verdict => {
  const text = deliveredText(run);
  if (text === undefined) return notApplicable('numbers-grounded');
  const g = ground(text, evidenceIndex([run.prompt, ...run.evidence], scales));
  if (g.total === 0) return notApplicable('numbers-grounded');
  const ok = g.ungrounded.length <= MAX_UNGROUNDED || g.ungrounded.length / g.total <= MAX_UNGROUNDED_SHARE;
  return ok
    ? pass('numbers-grounded')
    : fail('numbers-grounded', `${g.ungrounded.length}/${g.total} ungrounded: ${g.ungrounded.slice(0, 8).join(', ')}`);
};

// ─── Contract checks ─────────────────────────────────────────────────────────

const WEEKDAY = new Intl.DateTimeFormat('en-US', { timeZone: REVIEW_TIME_ZONE, weekday: 'short' });

export const tomorrowIsWeekday = (at: Date): boolean =>
  !['Sat', 'Sun'].includes(WEEKDAY.format(new Date(at.getTime() + 24 * 3600 * 1000)));

const applies = (run: Run, revision: SkillRevision, when: readonly Applicability[]): boolean =>
  when.every((a) => {
    switch (a.kind) {
      case 'prompt-says':
        return revision.promptTemplate.includes(a.text);
      case 'tomorrow-is-weekday':
        return tomorrowIsWeekday(run.startedAt);
      default:
        return assertNever(a);
    }
  });

/** What a command requirement can match: bash command lines, and reads as `read <path>`. */
const commandsOf = (run: Run): readonly string[] =>
  run.toolCalls.flatMap((c) => {
    switch (c.kind) {
      case 'bash':
        return [c.command];
      case 'read':
        return [`read ${c.path}`];
      case 'write':
      case 'edit':
      case 'other':
        return [];
      default:
        return assertNever(c);
    }
  });

const wroteTo = (run: Run, path: RegExp): boolean =>
  run.toolCalls.some((c) => {
    switch (c.kind) {
      case 'write':
      case 'edit':
        return path.test(c.path);
      case 'bash':
        return writeTargets(c.command).some((t) => path.test(t));
      case 'read':
      case 'other':
        return false;
      default:
        return assertNever(c);
    }
  });

const looked = (run: Run, path: RegExp): boolean =>
  run.toolCalls.some((c) => {
    switch (c.kind) {
      case 'read':
        return path.test(c.path);
      case 'bash':
        return namedFiles(c.command).some((f) => path.test(f));
      case 'write':
      case 'edit':
      case 'other':
        return false;
      default:
        return assertNever(c);
    }
  });

const requirementVerdict = (run: Run, revision: SkillRevision, req: Requirement): Verdict => {
  const id = `${req.kind}:${req.label}`;
  if (!applies(run, revision, req.when ?? [])) return notApplicable(id);
  const text = deliveredText(run);
  switch (req.kind) {
    case 'command':
      return commandsOf(run).some((c) => req.pattern.test(c)) ? pass(id) : fail(id, `no call matched ${req.pattern}`);
    case 'vault-write': {
      // Applies to ALL_CLEAR runs too: a background sync writes, then reports ALL_CLEAR.
      if (wroteTo(run, req.path)) return pass(id);
      const noOp = signalsAllClear(run) && req.noOp === 'read-counts' && looked(run, req.path);
      return noOp ? pass(id) : fail(id, `nothing written to ${req.path}`);
    }
    case 'output-matches': {
      if (text === undefined) return notApplicable(id);
      const flags = req.pattern.flags.includes('g') ? req.pattern.flags : `${req.pattern.flags}g`;
      const n = (text.match(new RegExp(req.pattern.source, flags)) ?? []).length;
      return n >= req.min ? pass(id) : fail(id, `${n} of ${req.min} required matches of ${req.pattern}`);
    }
    case 'max-lines': {
      if (text === undefined) return notApplicable(id);
      const lines = text.split('\n').filter((l) => l.trim().length > 0).length;
      return lines <= req.max ? pass(id) : fail(id, `${lines} lines, cap ${req.max}`);
    }
    default:
      return assertNever(req);
  }
};

const allClearAllowed = (run: Run, contract: SkillContract): Verdict =>
  run.outcome.kind === 'all-clear' && contract.allClear === 'forbidden'
    ? fail('all-clear-allowed', 'returned ALL_CLEAR; the skill has no nothing-to-report condition')
    : pass('all-clear-allowed');

/**
 * Every verdict for one completed run. A failed run gets none: its result is
 * already recorded as a reliability outcome.
 */
export const grade = (run: Run, revision: SkillRevision, contract: SkillContract | undefined): readonly Verdict[] => {
  if (run.outcome.kind === 'failed') return [];
  const universal = [
    sentinelExact(run),
    noLeakedMarkup(run),
    noQuestionToAbsentUser(run),
    notTruncated(run),
    withinTimeout(run, revision),
    numbersGrounded(run, contract?.numberScales ?? [1]),
  ];
  if (contract === undefined) return universal;
  return [
    ...universal,
    allClearAllowed(run, contract),
    ...contract.requirements.map((r) => requirementVerdict(run, revision, r)),
  ];
};
