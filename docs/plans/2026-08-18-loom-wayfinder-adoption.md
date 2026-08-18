# Adopting Wayfinder concepts into Loom

**Date:** 2026-08-18
**Source:** Matt Pocock, *Wayfinder* — https://youtu.be/F3lL98Pj90o
**Subject:** `~/dev/claude-plugins/loom` (command `loom` v3.2.0, plugin v1.1.0)
**Status:** Proposal. Nothing implemented.

## Decision

Adopt three things from Wayfinder: **decision tickets** as schedulable planning
work, **typed resolution mechanisms** for uncertainty (with prototype as a first
class one), and **provenance backlinks** from spec to the record that decided it.
Reject Wayfinder's issue-tracker-as-database and its non-persistent specs — Loom
is stronger on both. Ship the **frontier/fog status projection** first, because it
is the smallest change that makes the missing structure visible in daily use.

## What Wayfinder is

Wayfinder treats planning as map-making. You declare a *destination*, and the
agent charts a map of **decision tickets** in an issue tracker. Each ticket is a
unit of *planning* work sized to one agent session. The map tracks a **frontier**
(decisions that can be made right now) against **fog** (decisions blocked behind
other decisions). Tickets carry one of four types — research, prototype, grilling
(discussion), real-world task — and block each other. Resolving a ticket writes a
condensed resolution back to the parent map and moves the frontier. When the fog
clears, the map converts to a spec whose claims link back to the decision tickets
as primary source.

The load-bearing insight is not the tracker or the star map. It is this: **planning
is itself work that can exceed one session, and therefore needs decomposition and
dependency scheduling exactly like implementation does.**

## Where Loom stands today

Loom's phase machine (`engine/src/types.ts:85`):

```
init → brainstorm → specify → clarify → architecture → plan-alignment → decompose → execute
```

Each planning phase assumes it completes within a session and emits one artifact:
`brainstorm.md`, `spec.md`, a plan under `.claude/plans/`, `plan-alignment.md`.
Decomposition into a scheduled, dependency-ordered graph happens only at Phase 4,
and it decomposes **implementation** work: `decompose-agent` is capped at 8–12
tasks across 4–5 waves, 4–6 parallel per wave (`agents/decompose-agent.md:32`).

`Task` (`engine/src/types.ts:290`) is unambiguously an implementation task. Its
fields are `file_list`, `test_result`, `test_evidence`, `new_tests_written`,
`review_status`, `review_generation`, `review_run`, `proof`, `spec_anchors`. Not
one of those means anything for "decide whether we use Postgres or SQLite."

The phase machine is deliberately acyclic. There is exactly one sanctioned
back-edge — `plan-alignment → architecture`, and it must use `architecture-agent`
in single-agent mode (`engine/src/core/validate-phase-order.ts:259`).

### Loom already has the vocabulary of fog, but none of the machinery

This is the crux. Loom knows some uncertainty cannot be resolved in-phase:

- `clarify-agent` is capped at **max 5 questions per session** and is told
  *"Deferred items must have unblock conditions"* (`agents/clarify-agent.md:31`).
- `commands/clarify.md:217` defines a deferral syntax:
  `- FR-020: System MUST integrate with payment provider [DEFERRED: vendor selection pending]`
  with the rules *"Don't block spec completion / Must have clear unblock condition /
  Tracked in clarification log."*

So a `[DEFERRED]` marker is prose in `spec.md` plus a line in
`clarifications/log.md`. Nothing schedules it. Nothing owns it. Nothing checks
whether its unblock condition ever fired. Nothing surfaces it at `--status`.
`CanonicalStatusFacts` (`engine/src/types.ts:621`) carries `location`, `tasks`,
`failedProofObligations`, `testReadiness`, `reviewRuns`, `findingCounts`,
`refutationPanelNeed`, `waveGateCompletionEligibility` — there is no fact for
outstanding uncertainty. The spec proceeds to architecture carrying deferred
requirements that are, operationally, on the human to remember.

Loom named the concept and then let it fall on the floor.

## What NOT to adopt

**Issue-tracker-as-database.** Wayfinder's map *is* GitHub issues; state lives in
untyped issue bodies. Loom has a parser-proven `TaskGraph`
(`engine/src/types.ts:736`) with enforced immutability — every field is `readonly`
and every mutation must flow through `StateManager.update`'s locked transform,
with comments explaining precisely which invariant an in-place mutation would
bypass. It mirrors to `github_issue` for human visibility. Moving authority into
issue prose would trade proven invariants for a summary. Keep the tracker as a
projection, never as the source of truth.

**Non-persistent specs.** Matt closes the spec issue after implementation and
never refers back; the spec evaporates. That works because his implementation is
one AFK agent run. Loom's `spec-check` phase and wave gates read the spec *during*
execution, and `spec_anchors` on each task point into it. Deleting the spec breaks
the gates. Keep the spec live. (The kernel of truth — stale specs outliving their
usefulness — is worth handling at merge time, not by design.)

**"One skill does everything."** Wayfinder is a single skill so it can be portable
across agents. Loom deliberately has 28 typed agents with explicit LLM profile
bindings validated at spawn. That is a strength, not incidental complexity.

**Parallel fan-out with adversarial ranking.** Already present and stricter:
`--panel` runs an interviewer, N designers each with a distinct lens, adversarial
judges scoring against interview-derived criteria, then a finalizer. Nothing in
Wayfinder approaches this.

## Proposals

### 1. Frontier/fog status projection

**Ship first.** Smallest diff, immediately useful, and it makes the absence of the
rest tangible.

Extend `CanonicalStatusFacts` with an `uncertainty` fact projecting outstanding
`[NEEDS CLARIFICATION]` and `[DEFERRED]` markers, partitioned into what is
answerable now versus what is blocked and on what:

```ts
export type UncertaintyFacts = Readonly<{
  frontier: readonly OpenQuestion[];   // answerable right now
  fogged:   readonly OpenQuestion[];   // blocked, each carrying its unblock condition
}>;
```

Follow the existing `StatusFact` discipline: when the spec is unreadable this
reports `unavailable` with reasons, never a fabricated zero. `/loom --status`
then answers the question it currently cannot — *"what can I decide right now,
and what is still blocked?"* — which is Wayfinder's entire user-facing value.

This is a pure projection over data that already exists on disk. No schema change,
no new phase, no back-edge.

### 2. Decision tickets as first-class schedulable nodes

The substrate already exists — `decompose-agent` produces a dependency-ordered,
wave-scheduled, agent-assigned graph. It is simply pointed only at the second half
of the problem. Point it at the first half too.

A decision ticket must not be a `Task`. None of `test_result`, `review_status`,
`proof`, or `file_list` apply, and widening `Task` with a dozen optional fields is
exactly the illegal-state factory this codebase otherwise avoids. Split the node:

```ts
export type PlanNode =
  | Readonly<{ kind: "decision"; node: Decision }>
  | Readonly<{ kind: "implementation"; node: Task }>;

export type Decision = Readonly<{
  id: DecisionId;
  question: string;
  mechanism: ResolutionMechanism;   // see proposal 3
  depends_on: readonly DecisionId[];
  status: DecisionStatus;
}>;

export type DecisionStatus =
  | Readonly<{ kind: "open" }>
  | Readonly<{ kind: "in-session"; sessionId: string }>
  | Readonly<{ kind: "resolved"; resolution: string; anchor: ProvenanceAnchor }>
  | Readonly<{ kind: "abandoned"; reason: string }>;
```

**Frontier is derived, never stored.** An `open` decision whose `depends_on` are
all `resolved` is on the frontier; otherwise it is fogged. Storing a `frontier`
flag would let it drift out of agreement with the dependency graph — the exact
class of bug the `review_error` comment at `engine/src/types.ts:320` documents
having already been paid for once. Derive it.

Same rule for the artifact: the resolution text is written into the ticket, and
the map holds a projection of it. One writer, one source.

### 3. Typed resolution mechanisms

Loom's clarify has exactly one tool: ask the user, five questions at a time. But
markers fail to resolve for different reasons, and the reason determines what
would actually unblock them:

| Why it is blocked | Mechanism | Loom today |
|---|---|---|
| The user has not decided | interview | `clarify-agent`, `grill` ✅ |
| Nobody knows the answer yet | research spike | ad hoc, no representation |
| Unknowable without seeing it run | **prototype** | ❌ absent |
| Waiting on the outside world | errand | ❌ absent |

```ts
export const RESOLUTION_MECHANISMS = ["interview", "research", "prototype", "errand"] as const;
export type ResolutionMechanism = (typeof RESOLUTION_MECHANISMS)[number];
```

Tagging each marker with its mechanism turns *"ask five questions and hope"* into
routing. It also makes the existing 5-question cap principled rather than
arbitrary: interview markers get interviewed, and the rest get scheduled to the
thing that can actually answer them.

### 4. Prototype tickets — the anti-waterfall valve

The strongest single idea in the video, and Loom's largest structural risk.

Loom currently runs six phases — brainstorm, specify, clarify, architecture,
plan-alignment, decompose — entirely in low-fidelity prose. The first executable
artifact appears at Phase 5. That is a long chain of compounding commitment with
no empirical feedback, and `plan-alignment` and `spec-check` exist precisely
because that drift is real. Note what they do: they check documents against other
documents. There is no point in the pipeline where reality gets a vote before
implementation begins.

Grepping the entire tree for `prototype` returns only JavaScript's
`Object.prototype`. The capability does not exist.

A prototype ticket resolves an uncertainty by building throwaway running code and
looking at it. It is scoped to the question, not to the feature; its output is a
resolution plus a discarded branch, never a `file_list` that implementation
inherits. Matt's framing is right: heavy upfront planning becomes waterfall
*unless* prototypes keep injecting high-fidelity feedback, and the volume of
prototyping is what makes the eventual spec good.

This also aligns the pipeline with a standard already written into
`~/.dotfiles/claude/global/CLAUDE.md` — *"UI changes loaded in a browser before
reporting success."* Same instinct, applied where it is cheapest to act on.

### 5. Provenance backlinks

Matt's sharpest self-criticism transfers directly:

> "That was always a kind of weakness with grill with docs — you were really
> relying on the spec to be the source of truth, but the spec is always just a
> summary of what was actually said in the meeting."

`spec.md` is lossy. When `spec-check` or an implementation agent hits an ambiguity
mid-execution, it re-derives intent from the summary instead of reading what was
actually decided and why.

Loom already writes `clarifications/log.md`. Require stable anchors there, and
have spec requirements cite them the same way tasks already cite `spec_anchors`:

```ts
export type ProvenanceAnchor = Readonly<{
  artifact: string;   // e.g. ".claude/specs/{slug}/clarifications/log.md"
  anchor: string;     // stable heading id
}>;
```

`spec_anchors` on `Task` proves the pattern works and that the plumbing exists.
This extends the chain one link further back — from *what* we decided to *why* —
and gives `plan-alignment-agent` a primary source to diff against instead of a
paraphrase.

## The open design question

Proposal 2 requires a real decision about the phase machine, and it should be
made deliberately rather than discovered during implementation.

Wayfinder's core loop is *resolve a ticket → the frontier moves → new tickets
appear*. That is a cycle. Loom's machine is acyclic by design with one audited
exception (`validate-phase-order.ts:259`), and `validate-phase-order.sh` actively
blocks out-of-order agent spawns.

Two options:

1. **Contain the cycle inside a phase.** Decision tickets iterate within
   `clarify` (or a new `chart` phase between `brainstorm` and `specify`); the
   outer machine stays acyclic and sees one entry and one exit. Preserves the
   existing invariant. Risks re-inventing wave scheduling inside a phase.
2. **Legitimize a second back-edge.** A resolved decision may reopen `specify` or
   `architecture` for the affected sections. More faithful to how planning
   actually behaves; a genuine weakening of a property that has been deliberately
   defended, and it needs the same audit treatment the plan-alignment loop-back got.

Option 1 first. It is reversible, and a phase boundary is a cheaper place to
discover that the containment does not hold than the phase machine is.

## Sequencing

| # | Change | Size | Depends on |
|---|---|---|---|
| 1 | Frontier/fog projection in `--status` | small | — |
| 2 | `ResolutionMechanism` tag on markers | small | 1 |
| 3 | `Decision` node + `PlanNode` ADT, contained in one phase | large | 2, open question |
| 4 | Prototype mechanism + agent | medium | 3 |
| 5 | `ProvenanceAnchor` on spec requirements | small | 3 (rides along) |

Ship 1 and live with it before committing to 3. The projection will show exactly
where decisions currently have no home, and that evidence should shape the ADT
rather than the other way round.

## What this is not

Not spec-driven development. A Loom spec is a destination document for
multi-session work with gates that read it during execution — it is not a
maintained artifact that gets edited and re-edited as the source of truth. Matt's
distinction holds here even though his conclusion (delete the spec) does not.

Not more process for its own sake. Wayfinder's own guidance is the right gate:
if the work fits in one session, plan it in one session. Everything above should
be inert for small features and should only engage when there is genuine fog.
