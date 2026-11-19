# Reclaw scheduled skills — local vs cloud retrospective (B2a)

Grades every reclaw scheduled-skill run Pi recorded, local and cloud, with
deterministic checks. **Nothing is re-run**: the input is the session history
under `~/.pi/agent/sessions/--home-peterstorm-dev-claude-plugins-reclaw-workspace--/`.

It answers one question: *when reclaw's scheduled skills ran on the
workstation's local models (Sep–Oct 2026), was the output as correct as on
cloud models?* It also produces the graders that the fixture-replay benchmark
(B2b) reuses on the current local primaries.

Plan and context: vault note
`homelab/ai-workstation/planning/local-model-benchmark-coverage.md`.

```bash
bun install
bun test                      # 47 tests, ~0.1 s
bun run typecheck
bun src/cli.ts                # ~6 s, ~300 MB; writes report.md, flagged.md, runs.jsonl
bun src/cli.ts --since 2026-09-01 --until 2026-10-24 --out /tmp/retro
```

Output goes to `~/.local/share/bench/reclaw-skills-retro/<timestamp>/` by
default. **Never commit it**: the runs carry journal, health and finance text.

## Pipeline

| Stage | Module | What it does |
|---|---|---|
| Parse | `domain/session.ts` | Pi JSONL → `Run`. The run is the first user message up to the model's last turn before any reply (a Telegram reply resumes the session; that is chat). The outcome mirrors reclaw's runner: any provider error fails the run, the last text-bearing message is the delivery, an exact trimmed `ALL_CLEAR` is suppressed. |
| Classify | `domain/skill-catalog.ts` | Reclaw does not stamp the skill id into the prompt, and templates changed. Every committed revision of every `workspace/skills/*.yaml` is read from git; a *signature line* is a literal template line found in exactly one skill's history. ≥3 hits with a 2× margin attributes the run; the revision with most matching lines is the one that ran. |
| Grade | `domain/checks.ts`, `domain/contracts.ts` | Failed runs get no verdicts (reliability is reported separately). Completed runs get universal checks plus the skill's contract. |
| Report | `domain/report.ts` | Reliability per arm, clean-run rate per skill × arm and per model, per-check tables. Rates carry a 95% Wilson interval; cells under 10 runs show counts only. |
| Validate | `domain/crosscheck.ts` | Joins runs to reclaw's anomaly log (`~/.cache/reclaw/skill-quality.jsonl`, which names the skill of every suppressed/failed run) by start and end time and reports classifier agreement. |

`infra/` holds the only I/O: session files, `git log`/`git show` over the
reclaw repo, the anomaly log. Everything in `domain/` is pure.

## Checks

**Hard** checks decide whether a run is clean:

| Check | Fails when |
|---|---|
| `sentinel-exact` | A line of the delivered message is `ALL_CLEAR` once markdown is stripped: the model meant "nothing to report" but decorated or narrated it, so reclaw's exact match missed and the user was paged. A prose mention ("credential health was ALL_CLEAR") passes. |
| `no-leaked-markup` | `<think>`, tool-call syntax or chat-template tokens reached the message. |
| `not-truncated` | The final message stopped on the output-length cap. |
| `within-timeout` | The run outlasted the `timeout:` of the revision that ran. |
| `all-clear-allowed` | `ALL_CLEAR` from a skill with no nothing-to-report condition. |
| `command:<label>` | A script or file the prompt requires was never called/read. |
| `vault-write:<label>` | The required note was not written. Relative redirects resolve against the preceding `cd`; heredoc bodies and quoted awk/jq programs are not redirects. A no-op run that signalled all-clear and read the existing note passes (garmin-sync Step 3.5). |
| `output-matches:<label>`, `max-lines:<label>` | The message lacks required structure (tech-digest markdown links) or exceeds its line budget. |

**Heuristic** checks only flag runs for review:

| Check | Signal |
|---|---|
| `numbers-grounded` | Share of figures ≥10 in the message that appear in the prompt, tool outputs or injected memory context, modulo locale formatting, rounding and per-skill unit scales (øre → kroner). Derived values (EUR → DKK at a floating rate) are legitimately ungrounded. |
| `no-question-to-absent-user` | The message asks the absent user for permission. Regex over prose. |

A contract requirement binds a run only when **the prompt that ran contains
the clause** (`prompt-says`), never by calendar date; evening-journal's commute
weather additionally needs tomorrow to be a weekday in Europe/Copenhagen.

## Calibration log (2026-11-19)

The first run's flags were read by hand. Each grader fault found was fixed, the
run repeated, and the remaining flags re-read until every hard failure was a
verified defect.

| Found in review | Fix |
|---|---|
| Sentinel flagged prose mentions of `ALL_CLEAR` | Fail only on a sentinel line |
| running-coach "missed" `garmin-fetch` | The prompt reads the morning briefing's cache first; requirement is `garmin-data` (fetch or cache) |
| evening-journal "missed" commute weather on Fri/Sat | `tomorrow-is-weekday` applicability |
| procurement "missed" the ledger on old revisions | Ledger read binds only when the prompt has the upfront read |
| garmin-sync "missed" writes via `cd …; cat > 2026/10/x.md` | `cd`-relative redirect resolution |
| Weather figures ungrounded | JSON lists (`19.3,20.3`) are read element by element |
| Discount prices ungrounded | Prej returns øre: scale 0.01 |
| PR numbers ungrounded | Cortex memory surface (custom messages) is evidence |
| An 8,631 s cortex-prune "timeout" | Resume-time model/thinking/system entries ended the run late; run scope ends at the last model turn |
| A decorated no-op counted twice (sentinel + vault write) | No-op allowance keys on *signalled* all-clear |
| Classifier "errors" on same-minute skills | Join on start and end time; remaining mismatches verified as join artefacts (script skills and Claude-backend skills have no Pi session) |

Verified real after calibration: decorated sentinels (garmin-catchup, memory-librarian, reclaw-evolve, procurement), running-coach skipping its unconditional calendar step, procurement skipping the ledger read, four real timeouts.

## Limits

- **Not paired.** Local and cloud ran on different days with different inputs; the comparison is of rates.
- **Correct, not good.** Checks prove instructions were followed and nothing was invented or leaked; they do not judge usefulness or tone. That is B2b's LLM-judged pairwise step.
- **Local sample is one model.** 116 of 196 completed local runs are GLM-5.3 v14, a build no longer served. Qwen3.8-27B never answered (78/78 connection errors).
- **Claude-backend runs are out of scope.** Only Pi sessions are read, so both arms share one harness.
