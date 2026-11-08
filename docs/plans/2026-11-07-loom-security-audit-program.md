# Loom Security Audit Program

## Status

**Implemented — P0 through P7 landed** on branch `feat/security-audit-program`
(worktree `~/dev/claude-plugins/loom-security-audit`). See "Landed" below for the
commit map; the phases are kept as written so the plan can be read against what
shipped.

## Goal

Port `cloudflare/security-audit-skill` into Loom as a **registered program**
(`security-audit`) that finds vulnerabilities which cross a real trust boundary,
and hands confirmed findings to the existing remediation pipeline.

The port is deliberately asymmetric: Loom already implements in code what the
upstream skill specifies in prose (agent catalogs, model separation, frozen
emission schemas, refutation panels, evidence ledgers, write guards, run
directories, spawn budgets). So the upstream **taxonomy and epistemics** are
vendored; the upstream **orchestration prose is deleted**, because a second
prose copy of routing that the engine already owns is a divergence bug waiting
to happen (`docs/architecture.md`: "Loom code owns deterministic routing, identity,
validation, persistence, retries, aggregation, and state transitions").

## Non-goals

- Not a per-PR check. `/review-pr` reviews a diff; this sweeps a repository.
- Not a fixer. Audit produces records; `/review-and-fix` patches under its own
  fail→pass gate and verified-index install.
- Not a scanner. Upstream's own fleet run invoked Semgrep zero times in a month;
  do not invest in static analysis the hunters ignore.
- Not a replacement for `security-expert` (reactive guidance) or `security-agent`.

## Provenance

- Upstream: [`cloudflare/security-audit-skill`](https://github.com/cloudflare/security-audit-skill),
  MIT, pinned `c1c8a8c`, 22 files / 5,382 lines. Validators are zero-dependency
  Node and their 65 tests pass on node 22.23.3.
- Design rationale: ["Build your own vulnerability harness"](https://blog.cloudflare.com/build-your-own-vulnerability-harness/).
- Local analysis: session of 2026-11-07 (repo cloned to `/tmp/cf-sa`; not retained).

## What Loom already provides

Verified against the working tree, not assumed:

| Upstream requirement | Loom primitive |
|---|---|
| "the verifier is never the hunter" | Agent Catalog kinds + per-agent model profiles (`refutation`, `focused-review`); Refutation Panel k-of-n with `security`, `blast-radius`, `reproduction`, `intent` lenses (`references/review-lenses.md`) |
| structured output that cannot be prose-wrapped | frozen reviewer payload v2 + emission tools + `Readiness Barrier` (`docs/adr/ADR-0012`, `ADR-0015`) |
| write isolation, parent-owned artifacts | `core/artifact-write-scope.ts`, `core/block-direct-edits.ts`, Pi write grants |
| "reviewed_paths" as evidence | `pi/evidence-recorder.ts` → machine ledger `FileRead` / `TestRun` facts per epoch |
| coverage accounting | `core/defect-family-accounting.ts`, `core/family-sites.ts` |
| cross-run resume | immutable Run Directory + `core/ledger-epoch-view.ts` |
| tool wishlist (upstream's most-used mechanism) | `await-user` action |
| hunter cannot edit source to make a PoC pass | `machines/*.machine.json` `enforcedTools` + `guard` hooks |
| agent/model policy | `core/model-profiles.ts` (`AGENT_CATALOG`), `scripts/sync-pi-agents.sh` |
| context assembly ("copy these blocks verbatim") | Context Packets (`core/context-packets.ts`) |

## What is genuinely missing

1. **No OS-enforced sandbox.** Verified: nothing in Loom isolates a
   target-controlled build. `unshare` exists on this host; `bwrap` does not.
2. **No bounded-execution evidence event.** A hunter can claim it reproduced
   something; nothing records limits, allowlisted env, or scratch bytes.
3. **No coverage-ledger state machine** with the "never silently unassigned"
   obligation. `defect-family-accounting` accounts *declarations*; it does not
   schedule unit assignment.
4. **No vulnerability verdict vocabulary.** Loom's `FindingSeverity` is
   `critical | advisory` and is a refutation ballot; upstream needs
   `confirmed | needs_validation | rejected`, where `needs_validation` carries
   **no severity at all**.

## Decisions

**D1 — Program, not skill-side workflow. (ADR-0064.)**
A new registered program under `engine/src/handlers/helpers/programs/security-audit/`,
sibling to Standalone Review, driven by the existing closed action set
(`spawn-batch`, `await-user`, `blocked`, `done`). The skill holds judgement only.
*Rejected:* a fat `skills/security-audit/SKILL.md` that orchestrates by prose —
it would duplicate scope derivation, roster selection, retries, aggregation, and
publication that the engine already owns.

**D2 — Reuse reviewer payload v2 for hunter candidates.**
Loom's Finding already carries preconditions, violated contract, consequence and
evidence limits — upstream's `confirmed` record minus the fingerprint and the
five-level severity ladder. The trichotomy lives in the coverage ledger and the
published `security-findings.json`, not on the wire.
*Rejected (for now):* a fourth producer kind (`security-finding`) with its own
frozen emission schema. Better strict-sampling, but it touches
`agent-catalog-projections`, `core/emission-tool`, `scripts/stamp-wire-contract`,
probes and route qualification — roughly +2 days for a guarantee v2 already
gives.

**D3 — Severity: keep loom's ballot, carry upstream's ladder as a recorded field.**
Adjudication stays `critical | advisory` with no downgrade authority
(`references/review-lenses.md`: "there is no severity ballot, score, downgrade or
advisory-conversion authority"). Upstream's `overall_severity`
(critical/high/medium/low/informational) is recorded and refutable, never
silently rewritten. Enforced invariant: overall severity ≤ demonstrated impact.

**D4 — Run directory inside the Loom run root, `--out` overridable.**
Engine refuses an in-repo output directory unless `git check-ignore` passes
(upstream's rule, kept).

**D5 — Vendor the taxonomy verbatim; do not rewrite it.**
`references/security-lenses/` holds the eleven upstream domain docs with their
`Core discipline` / `Universal moves` / `Validation rules` sections intact,
because those sections are injected into prompts and their byte-fidelity is the
point. Deltas live in `ATTRIBUTION.md` + a single `LOOM-DELTAS.md`, so
re-vendoring is a diff, not a reconciliation.

**D6 — Command name `/security-audit`; program kind `security-audit`.**
Distinct from `/review-pr` (diff-scoped) and `/security-expert` (advice).
*Alternative considered:* `/security-sweep`, which signals periodicity better.

## Keep / drop / add

**Keep (upstream's good parts):** verdict trichotomy; `needs_validation` has no
severity; `rejected` records retained so future runs don't re-litigate a
disproved claim; boundary-and-result gate ("no affected principal/resource ⇒ not a
finding"); "defense-in-depth gap is not a vulnerability"; severity ≤ demonstrated
impact; smallest effective fix at the last trusted decision point; coverage
ledger with explicit `deferred` reasons; budget spent as counted agent
invocations with reserves for critics and validation; additive multi-run
semantics with fingerprints; guidance mode vs full-audit mode; no-follow,
path-confined, size-bounded promotion of target-controlled scratch.

**Drop (Loom owns it):** the 11-step artifact-promotion procedure (duplicated
three times upstream — replaced by write grants + guards, with upstream's
no-follow rules retained for scratch→artifacts); budget arithmetic prose
(replaced by engine counters + spawn admission); "copy these blocks verbatim"
prompt assembly (Context Packets); `research`/`general` agent vocabulary (Agent
Catalog); "run `node validate-*.cjs`" instructions (engine validation action);
Windows device-name / case-fold paranoia (loom path guards).

**Add (Loom-side, new):** sandboxed local execution with recorded limits; a
coverage-ledger state machine; coverage-critic agent; security-hunter/verifier
agents; report renderer; calibration cases.

## Phases

Each phase is independently shippable. Do not start a phase before the previous
phase's invariants are green.

### P0 — ADR (0.5d)
`docs/adr/ADR-0064-security-audit-is-a-registered-program.md`: D1–D6, with the
rejected fourth-producer-kind option recorded (D2). Blocks everything else.

**Done when:** ADR merged; `docs/README.md` / `docs/architecture.md` system map
mentions the new program in the same commit as P5, not before.

### P1 — Vendor the taxonomy (0.5d)
`references/security-lenses/`: `attack-classes.md`, `web-protocol-and-auth.md`,
`client-side.md`, `ai-and-llm.md`, `memory-safety-and-binary.md`,
`supply-chain-and-release.md`, `cloud-and-deployment.md`,
`protocols-rpc-and-messaging.md`, `resource-exhaustion-and-availability.md`,
`data-isolation-and-lifecycle.md`, `desktop-mobile-and-local-ipc.md`;
plus `ATTRIBUTION.md` (URL, commit `c1c8a8c`, MIT, retrieval date) and
`LOOM-DELTAS.md`.

Lens-selection rule (new, upstream had none): derive 2–3 lenses from the target's
stack and rank them; never inject all eleven. Selection is a pure function over
detected languages/manifests so it is testable.

**Done when:** `references/` files are byte-identical to upstream except for a
documented header stanza; a `loom-deltas` test asserts no undocumented drift
against a pinned digest list.

### P2 — Pure cores: contract, ledger, findings (2d)
New leaf modules, no I/O, no clock, no randomness:

- `engine/src/core/security-audit-contract.ts` — versioned contract: profile
  (`quick|standard|deep`), scope paths, `source_ref` + dirty flag, budget
  (max agent invocations, `null` = unset), coverage-unit identity
  `(surface, boundary, subsystem, attack_class)`, verdict record shapes,
  fingerprint rule `^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$` (no line/wave/agent/severity
  component), `incomplete_reason` tokens.
- `engine/src/core/security-coverage.ts` — ledger state machine:
  `planned → in_progress → covered | candidate | blocked | deferred`, `attempts[]`
  archive on critic reassignment, wave counter, canonical-ID derivation,
  collision = hard failure, per-unit disposition exactly once.
- `engine/src/core/security-findings.ts` — trichotomy parse with
  `additionalProperties: false` semantics; `needs_validation` has no severity
  field and no confirmed `root_cause`; `rejected` retains `reason`;
  `confirmed` requires bounded `observed_result`.

**Tests** (fast-check properties + fixtures):
- every assigned unit has exactly one terminal disposition, or the ledger is invalid;
- severity overall ≤ demonstrated impact, for all generated records;
- a prior `confirmed` carries only when the relevant source is unchanged; a
  changed-source unit is never suppressed by a prior run;
- budget exhaustion yields `incomplete` with a reason token — never a clean-coverage claim;
- canonical ID collision fails rather than merging;
- **differential oracle:** the TS parser and upstream's `validate-findings.cjs` /
  `validate-coverage-ledger.cjs` (vendored to `engine/tests/fixtures/security/`)
  agree on a shared corpus. This inherits upstream's 65 tests' edge cases
  (surrogate pairs, zero-width characters, Windows device names, path traversal,
  `additionalProperties` violations) without importing their runtime.

**Done when:** lint-clean (`scripts/lint-project.ts`), purity rules hold, oracle
agrees on ≥40 fixtures including upstream's own producer-compatible ones.

### P3 — Agents, machines, catalog (1.5d)
- `agents/security-hunter-agent.md` — tools: read/grep/find/ls/bash; **no**
  edit/write; machine-gated `read-context → hunt → local-check → emit` with
  `enforcedTools: ["Edit","Write","MultiEdit"]` denied throughout, so a hunter
  structurally cannot edit source to make its own reproduction pass.
- `agents/security-critic-agent.md` — coverage critic; returns `missing_units`,
  `reassign_ids`, `resolved_prior_leads`, `stop`; reads source, writes nothing.
- `agents/security-verifier-agent.md` — `refutation` profile, different provider
  from the hunter, read-only.
- `machines/security-hunter-agent.machine.json`.
- `AGENT_CATALOG` records in `core/model-profiles.ts`; projections derive from the
  catalog (no second source).

**Done when:** `scripts/sync-pi-agents.sh` renders all three; a test asserts
hunter and verifier profiles differ and that the hunter has no mutating tool;
one smoke run on a tiny fixture repo completes recon → one hunt → one refutation
with a validated `security-findings.json`.

### P4 — Bounded local execution (1d)
- `scripts/security-sandbox.sh`: `unshare -Urmn --fork`, `env -i` from an
  allowlist, read-only bind of target + toolchain, tmpfs scratch, `ulimit` for
  CPU / memory / processes / file size, `timeout`. Optional: add
  `pkgs.bubblewrap` to the dotfiles pi module if `unshare` proves too coarse.
- `engine/src/core/security-sandbox.ts` — pure limits/env-allowlist policy and
  the `SandboxRun` record shape.
- Pi evidence recorder gains `SandboxRun` (exit status, limits, allowlisted env
  **names**, byte caps), so a `needs_validation` blocker cites a fact.
- Keep upstream's promotion rules for scratch → artifacts (no-follow, single
  link, bounded size, exclusive create).

**Done when:** a fixture that writes outside scratch or opens a socket is denied,
and the denial is recorded; absence of a sandbox capability produces a
`needs_validation` blocker, never an execution claim.

### P5 — The program (1.5d)
`engine/src/handlers/helpers/programs/security-audit/`: registration, scope
derivation, roster selection, context packets, spawn batches, retries, critic
waves, panel refutation, publication.

- Actions stay in the closed set; the orchestrator never hand-builds state.
- The **engine** counts invocations against budget and refuses a hunter wave that
  would starve the critic + validation reserve.
- Publication writes the immutable run dir: `run-metadata.json`,
  `coverage-ledger.json`, `security-findings.json`, and the three derived reports
  `REPORT.md`, `FINDINGS-DETAIL.md`, `NEEDS-VALIDATION.md` — rendered by code from
  validated records so prose cannot drift from JSON.
- Profiles bound the loop: `quick` = one hunter wave + one critic pass;
  `standard` = waves to a clean post-wave critic plus a distinct final-clean
  critic; `deep` = per-subsystem units, separate Phase-3 and Phase-5 verifiers,
  second pass on prior-same-source units.
- `commands/security-audit.md` + `skills/security-audit/SKILL.md` (judgement only,
  ~120 lines: modes, boundary gate, severity anchors, anti-patterns, lens
  selection, when to `await-user` for a missing capability).

**Done when:** `/security-audit --profile=quick` on a fixture repo produces a
valid run dir, both validators pass, reports derive and match the JSON exactly.

### P6 — Remediation handoff (0.5d)
Published `confirmed` records map into `standalone-disposition`, so a following
`/review-and-fix` can consume finding IDs without a caller minting replacements.
Audit never patches.

**Done when:** a fixture confirmed finding round-trips into a disposition and the
existing repair path accepts it.

### P7 — Make it honest (1d)
- Calibration cases in `calibration/`: fixtures with planted defects, one per
  boundary class (authz gap, path traversal, tenant leak, injection, token
  lifetime, SSRF, unsafe deserialization, replay).
- Metrics recorded per run: confirmed / `needs_validation` / rejected split,
  coverage cells closed per agent invocation, rejection rate across successive
  runs (upstream's real signal — no recall claim, since no complete label set exists).
- `docs/operations.md` runbook section; `docs/model-profiles-and-calibration.md`
  note on hunt-vs-verify model separation.
- Contract preflight test in the `command-preflight-contract` family.

**Done when:** three consecutive runs on the same fixture leave the ledger
monotonically more covered and never re-report a rejected claim without changed
evidence.

## Surface delta

```
loom/
  commands/security-audit.md                                      new
  skills/security-audit/SKILL.md                                  new
  references/security-lenses/*.md                                 new (11 + ATTRIBUTION + LOOM-DELTAS)
  agents/security-hunter-agent.md                                 new
  agents/security-critic-agent.md                                 new
  agents/security-verifier-agent.md                               new
  machines/security-hunter-agent.machine.json                     new
  engine/src/core/security-audit-contract.ts                      new
  engine/src/core/security-coverage.ts                            new
  engine/src/core/security-findings.ts                            new
  engine/src/core/security-sandbox.ts                             new
  engine/src/handlers/helpers/programs/security-audit/*.ts        new
  engine/src/core/model-profiles.ts                               edit (3 catalog records)
  pi/evidence-recorder.ts                                         edit (SandboxRun)
  scripts/security-sandbox.sh                                     new
  engine/tests/security-*.test.ts + fixtures/security/            new
  calibration/ (new cases)                                        edit
  docs/adr/ADR-0064-*.md                                          new
  docs/architecture.md, docs/operations.md                        edit (at P5/P7)
```

## Invariants

- **INV-S1** A hunter cannot write outside its scratch. Tested by attempting an
  `Edit` in an orchestrated run and asserting denial; ad-hoc ungated launches are
  not evidence.
- **INV-S2** Every unit assigned to a wave reaches exactly one terminal
  disposition; otherwise the ledger is invalid and no further wave may be assigned.
- **INV-S3** No record enters `security-findings.json` without an independent
  verifier whose catalog profile differs from the hunter's.
- **INV-S4** `needs_validation` carries no severity — enforced at parse, not by
  convention.
- **INV-S5** A strict budget is never exceeded silently: either `incomplete` with
  a reason token, or every planned unit has a terminal state.
- **INV-S6** `REPORT.md` is derived from validated records; a divergent report
  fails CI.

## Risks

| Risk | Mitigation |
|---|---|
| The security ledger becomes a second accounting kernel beside `defect-family-accounting` | Contract ADR states one owner; security units are *declared into* the existing family accounting, never a parallel proof path |
| `references/` drift makes re-vendoring expensive | Pinned digest list + drift test, deltas in one file |
| Upstream density (~2,300 lines of orchestration prose) survives the port | Deletion list is explicit (see Drop); skill stays under ~120 lines |
| Hunter prompts exceed the "keep children under 25% context" budget | Context Packets + 2–3 lenses, not 11; record prompt bytes per spawn in calibration |
| Sandbox on NixOS is coarse (`unshare` only) | Ship `unshare` version, document the limits it cannot enforce, degrade to `needs_validation` |

## Open questions

1. `quick` profile: is one hunter wave worth shipping, or does it only produce
   plausible-looking partial coverage? Decide from P7 calibration data.
2. Do we need a `deep` per-subsystem split at all for repos under ~30k LOC?
3. Should `security-audit` runs be registered in the same Run Directory namespace
   as review runs, or a sibling root? (Affects `ledger-epoch-view` queries.)

## Landed

| Phase | Commit | What it produced |
|---|---|---|
| P0 | `docs/adr/ADR-0064` | the program decision: registered, deterministic coverage, split profiles, counted budget |
| P1 | `5c5a32b4` | 11 lens documents byte-identical to upstream + `MANIFEST.json`/`ATTRIBUTION.md` + oracle fixtures |
| P2 | `5c5a32b4` | `security-audit-contract`, `-coverage`, `-findings`, `-lens-select`, `-reports`, `-sandbox`, `-adjudication` (pure cores, property-tested) |
| P3 | `5c5a32b4` | hunter/verifier/critic agents, `security-verdict` catalog kind, hunter machine |
| P4 | `553fe426` | `scripts/security-sandbox.sh` (unshare, ro remount, ulimits, receipt) + `SandboxRun` evidence kind |
| P5 | `d4290f24` | `helper security-audit` — ten closed operations, traits table, run directory, no-follow writes |
| P6 | `d4290f24` | `disposition` — one decision per published record, derived, handed to `/review-and-fix` |
| P7 | `115826e6` | calibration fixture (one planted defect per class), `docs/security-audit.md` runbook, profile-scoped lens cap |
| — | `34cc1f1b` | distill pass (one fingerprint-order owner) |

Follow-the-plan deviations, each recorded where it happened:

- the lens cap was a selector default of 3; calibration showed a `deep` run over
  a six-lens application holding three, so the cap moved to
  `SECURITY_PROFILE_LENSES` (quick 2 / standard 4 / deep 8) — the profile owns
  the context budget it was already declaring.
- `submit` now sorts a hunter's wire list by fingerprint before validating, so a
  hunter is not refused for a document-ordering rule it never sees.
- P2 shipped as seven modules, not five: `-sandbox` and `-adjudication` were
  split out when both grew their own parsers.
- the shared test builders (`engine/tests/security/fixtures.ts`) and the
  `switch-totality` lint rule were pulled forward — the first because ten test
  files were hand-rolling the same literals, the second because P2's verdict
  dispatch was the exact shape the house rule forbids.

## Sequencing

`v0` = P0 + P1 + P3 + a minimal command, without the engine program: ~1 day,
already better than upstream for daily use (vendored taxonomy on demand, enforced
read-only hunters, model separation), but leaves the ledger as hand-written JSON.
Then P2 → P5 (the actual moat), then P4, then P6, then P7.

Estimated total: ~8 days agent-assisted.

## Definition of done

- `/security-audit` on a fixture repo produces a valid, immutable run dir whose
  reports are byte-derived from validated records.
- Both validators disagree with nothing: TS parsers and upstream's CJS validators
  agree on the shared corpus.
- A hunter that tries to edit source is denied and the denial is in the ledger.
- Budget exhaustion is impossible to hide.
- A confirmed finding round-trips into `/review-and-fix`.
- Calibration shows rejection rate falling across runs without new findings
  collapsing to zero.

## Review-and-fix pass (2026-11-07)

The shipped program went through an independent panel: eight reviewer roles in
three waves of three (`code-reviewer`, `architecture-tech-lead`,
`silent-failure-hunter`, `type-design-analyzer`, `security-agent`,
`ts-test-agent`, `code-simplifier`, `comment-analyzer`), then a
`review-verifier-agent` refutation pass over the 15 most consequential claims.
**15/15 confirmed; 0 refuted.** Remediation is `f3ff3a7e`.

What the panel found that matters for the design, not just the code:

- **INV-S3 was a comment, not a check.** A ballot's `profile` was free prose, so
  a hunter could certify its own claim by writing `profile: "refutation"`. The
  fix makes profile identity structural: the profile must be in the catalog and
  must be the one the voting agent sits on.
- **"Total" validators weren't.** `validateLedger` threw on `[{}]` — the one
  input a hand-edited ledger produces. Totality is now a property test that
  feeds `fc.anything()` at it.
- **Evidence that could be prose.** A `local` check only had to *name* an
  artifact. The engine now reads the receipt and judges it (exit zero, measured
  scratch, limits actually applied), and the receipt itself reports what the
  kernel enforced rather than what the caller requested.
- **One root cause, one record** was implemented on root-cause TEXT alone, which
  silently dropped a finding when a hunter reused a sentence. Consolidation now
  also requires the same sink.
- **The docs were the contract and they had drifted**: the hunter documented
  `unitStatus`/`localChecks`, the critic `requeue`/`unprovenClaims`, the verifier
  a `security-refutation` kind with a `refutation` block. All three would have
  been refused by the real parsers. There is now a test that reads the JSON
  blocks out of the agent docs and checks their key sets against the parsers'
  allowlists, so documentation drift fails CI.

Two environment facts worth keeping:

- The registered `/review-and-fix` façade (`helper orchestration start
  standalone-review`) could not run in the session: the loaded Pi extension
  carried revision `ab6025de`, which no clean worktree reproduces (probes:
  `bcf52332` at HEAD, `6873ba40` at the base commit). The panel ran directly
  instead, and the façade blockage is reported rather than worked around —
  unsetting the admission env vars to force it would have been the forbidden move.
- Running vitest **inside** Pi fails ~495 tests with runtime-skew errors unless
  `PI_CODING_AGENT`, `LOOM_PI_EXTENSION_RUNTIME_ROOT` and
  `LOOM_PI_EXTENSION_RUNTIME_REVISION` are unset for the child process.

Still unbuilt and still worth building: `commands/security-audit.md` (the
slash-command surface). Everything else in the plan shipped.

## Second review-and-fix campaign (registered façade)

The first pass ran the panel directly because the façade was runtime-skew
blocked. Once the Pi extension revision matched the checkout, the same review
ran the way it is meant to: `helper orchestration start standalone-review` →
`resume` → `subagent` per issued task → `resume` for the refutation batch →
`resume` publishes. Six slices, because one scope could not fit the context
budget (`cores-a`, `cores-b`, `handler`, `tests-core`, `tests-other`, `docs`);
scope was narrowed with the stdin `files` field, **not** the `--files` flag,
which does not narrow scope at all.

**54 reviewer slots, 49 surviving critical findings, 204 advisory, 0 refuted.**
The criticals dedupe to 22 distinct defects; all 22 are remediated, each pinned
by a test.

What this pass found that the first one could not:

- **Enforcement facts must not round-trip through a file the command can
  write.** The sandbox receipt was built from `$scratch/.enforcement`, inside
  the one directory the command owns — so a command that refused its own
  `ulimit` could still report it as applied. The facts now travel on the *inner
  shell's* stdout, which the command cannot reach (its stdout is redirected to
  `$scratch/.command-stdout`), and the receipt marker carries a caller nonce
  derived from the artifact path. Two independent defences against a forged
  receipt line.
- **A remount that fails is counted, never swallowed.** `|| true` in the
  per-mount loop hid how much writable surface a run actually had.
- **Gate the provable surface, record the rest.** A user namespace cannot
  remount a superblock it does not own (227 mounts on this host), so gating
  `unremountedMounts === 0` would refuse every run. What *is* provable is the
  user's home: bind-then-remount-ro succeeds because the uid mapping makes the
  caller its owner. So `homeReadOnly` is the gate; `readOnlyRoot` and
  `unremountedMounts` are recorded exposure.
- **The run directory's reads are fail-closed, one document at a time.** An
  absent `findings.json` was indistinguishable from "the run found nothing", so
  a deleted file read as an empty result. Absence is now a refusal naming the
  path, and every document is re-parsed on read rather than cast.
- **Documentation drift is a runtime failure, not a doc bug.** The agent docs
  are the wire contract; a doc naming a key the parser refuses is an agent whose
  output the engine discards. The doc test now imports the parsers' own
  `UNIT_RESULT_KEYS` / `CHECK_KEYS` / `CRITIC_KEYS` / `CRITIC_PROPOSAL_KEYS` /
  `VERDICT_KEYS` instead of hand-copying them, so the two cannot drift apart —
  and the critic's proposal allowlist, which had never existed, now refuses
  invented keys instead of silently dropping them.
- **One owner for path normalization.** Two `repoRelative` implementations
  disagreed, so every `pi/…` baseline key was dead and only looked consumed.
  `baseline.ts` now owns both the keys and the normalization, and the drift
  pass walks the baseline's own paths so a scoped lint run no longer reports
  every other entry stale.
- **A differential oracle needs two assertions, not one restated twice.** The
  "we never accept what upstream rejects" loop compared `upstream` against
  `ours || upstream`, which can only fail when the first assertion already
  failed. It now asserts the rejection set directly and pins, by name, the one
  mutation where this port is deliberately stricter than the vendored validator.
- **Routing traits are pinned by spawning the real CLI with an open stdin**,
  which is the parent-shell shape that hangs any route reading to EOF — the
  trait table was previously the only witness, and a table cannot be wrong about
  the code it predicts.

The slash-command surface shipped last: `commands/security-audit.md`, bound to
the operation table by
`engine/tests/handlers/security-audit-command-contract.test.ts` so it cannot
name an operation the program does not declare, omit one it does, disagree about
which operations read stdin, or repeat the claim that a read-only projection
survives a runtime skew when its traits say otherwise.
