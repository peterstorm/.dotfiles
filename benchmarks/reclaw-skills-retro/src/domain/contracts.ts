// Per-skill contracts, transcribed from each skill's YAML in the reclaw repo
// (workspace/skills/<id>.yaml). A requirement that a later prompt revision
// introduced carries `prompt-says` with the clause's own text, so a run is
// only held to what the prompt it actually received told it to do.
//
// Skills absent here are graded on the universal checks only.

import type { Applicability, SkillContract } from './checks.ts';
import { SkillId } from './model.ts';

const says = (text: string): Applicability => ({ kind: 'prompt-says', text });

/** `personal/fitness/YYYY/MM/…` before the 2026-11-17 vault reorganisation, `personal/fitness/log/YYYY/MM/…` after. */
const FITNESS_NOTE = /remotevault\/personal\/fitness\/(?:log\/)?\d{4}\/\d{2}\/\d{4}-\d{2}-\d{2}\.md/;
const MARKDOWN_LINK = /\[[^\]\n]+\]\(https?:\/\/[^)\s]+\)/;
/** The morning briefing caches the Garmin pull; later skills read the cache and fetch only when it is missing. */
const GARMIN_DATA = /garmin-fetch\.ts|\.cache\/garmin\/daily\//;

export const CONTRACTS: readonly SkillContract[] = [
  {
    skill: SkillId('garmin-sync'),
    // "Respond with exactly ALL_CLEAR — this is a background data sync."
    allClear: 'allowed',
    numberScales: [1],
    requirements: [
      { label: 'garmin-data', kind: 'command', pattern: GARMIN_DATA },
      // A re-run on an unchanged day reads the existing note and stops (Step 3.5).
      { label: 'fitness-note', kind: 'vault-write', path: FITNESS_NOTE, noOp: 'read-counts' },
    ],
  },
  {
    skill: SkillId('garmin-catchup'),
    allClear: 'allowed',
    numberScales: [1],
    requirements: [{ label: 'garmin-data', kind: 'command', pattern: GARMIN_DATA }],
  },
  {
    skill: SkillId('morning-briefing'),
    allClear: 'forbidden',
    numberScales: [1],
    requirements: [
      { label: 'commute-weather', kind: 'command', pattern: /commute-weather\.ts/, when: [says('commute-weather.ts')] },
      { label: 'garmin-data', kind: 'command', pattern: GARMIN_DATA },
      { label: 'calendar-events', kind: 'command', pattern: /calendar-events\.ts/, when: [says('calendar-events.ts')] },
      // "under ~25 lines"; the tilde buys a little slack.
      { label: 'about-25-lines', kind: 'max-lines', max: 30, when: [says('under ~25 lines')] },
    ],
  },
  {
    skill: SkillId('evening-journal'),
    allClear: 'forbidden',
    numberScales: [1],
    requirements: [
      { label: 'calendar-events', kind: 'command', pattern: /calendar-events\.ts/, when: [says('calendar-events.ts')] },
      {
        label: 'commute-weather',
        kind: 'command',
        pattern: /commute-weather\.ts/,
        // "Commute weather (weekdays only): If tomorrow is a weekday (Mon-Fri) …"
        when: [says('commute-weather.ts'), { kind: 'tomorrow-is-weekday' }],
      },
    ],
  },
  {
    skill: SkillId('tech-digest'),
    allClear: 'allowed',
    numberScales: [1],
    requirements: [
      { label: 'fetch-feeds', kind: 'command', pattern: /fetch-feeds\.ts/, when: [says('fetch-feeds.ts')] },
      { label: 'mark-seen', kind: 'command', pattern: /fetch-feeds\.ts\s+--mark/, when: [says('fetch-feeds.ts --mark')] },
      // "every item needs its real URL" as a markdown link — the recurring link-free digest bug.
      { label: 'markdown-links', kind: 'output-matches', pattern: MARKDOWN_LINK, min: 3, when: [says('[Title](link)')] },
    ],
  },
  {
    skill: SkillId('homelab-watchdog'),
    allClear: 'allowed',
    numberScales: [1],
    requirements: [
      { label: 'disk', kind: 'command', pattern: /\bdf\b/ },
      { label: 'k8s-nodes', kind: 'command', pattern: /kubectl get nodes/ },
      { label: 'k8s-pods', kind: 'command', pattern: /kubectl get pods/ },
      { label: 'memory', kind: 'command', pattern: /\bfree\b/ },
      { label: 'reclaw-service', kind: 'command', pattern: /systemctl --user [^|;&]*reclaw/ },
    ],
  },
  {
    skill: SkillId('workstation-procurement-watch'),
    allClear: 'allowed',
    numberScales: [1],
    requirements: [
      { label: 'listing-cache', kind: 'command', pattern: /\.cache\/reclaw\/workstation-procurement\.json/ },
      {
        label: 'acquisition-ledger',
        kind: 'command',
        pattern: /workstation-procurement\/MOC\.md/,
        // The upfront ledger read; earlier revisions touched the MOC only in the Monday report step.
        when: [says('workstation-procurement/MOC.md && cat')],
      },
    ],
  },
  {
    skill: SkillId('running-coach'),
    allClear: 'forbidden',
    numberScales: [1],
    requirements: [
      { label: 'garmin-data', kind: 'command', pattern: GARMIN_DATA },
      { label: 'calendar-events', kind: 'command', pattern: /calendar-events\.ts/, when: [says('calendar-events.ts')] },
    ],
  },
  {
    skill: SkillId('credential-health'),
    allClear: 'allowed',
    numberScales: [1],
    requirements: [{ label: 'credential-health', kind: 'command', pattern: /credential-health\.ts/ }],
  },
  {
    skill: SkillId('discount-watch'),
    allClear: 'allowed',
    // Prej returns prices in øre; the message states kroner.
    numberScales: [1, 0.01],
    requirements: [{ label: 'prej-api', kind: 'command', pattern: /api\.prej\.app/, when: [says('api.prej.app')] }],
  },
  {
    skill: SkillId('weekly-review'),
    allClear: 'forbidden',
    numberScales: [1],
    requirements: [],
  },
];

export const contractFor = (skill: SkillId): SkillContract | undefined => CONTRACTS.find((c) => c.skill === skill);
