# Verification Loops: The Agent-Centric Development Cycle

*Learned: August 2026*
*Source: [In the Land of AI Agents, the Verifiers Are King — Tariq Shaukat, Sonar](https://youtu.be/VrpEyglYgeU) (AI Engineer conference keynote)*
*Third of a series of four: [neuro-symbolic-guardrails.md](neuro-symbolic-guardrails.md) (what to
check: domain invariants, deterministically), [eval-calibration.md](eval-calibration.md) (how to
trust the checkers: calibrate judges like classifiers), this one (where the checks live: every loop
of the development cycle, so they compound), and [agent-optimization.md](agent-optimization.md)
(trusted checks as fitness functions: gate becomes gradient).*

**Bias note:** vendor keynote by Sonar's CEO. The framework maps onto Sonar's product line
(SonarQube, the just-launched Sonar Vortex), and the headline numbers (30% tokens, 44% outages,
92% issues) are Sonar's own unpublished customer data. The argument stands independently; treat
the figures as marketing-grade.

## The Thesis

As coding agents get dramatically more capable, the bottleneck shifts from
generation to verification. Verification must be baked into every loop of the
software development lifecycle — not bolted on as after-the-fact code review.
The system compounds in both directions: neglect it and gains evaporate; embed
it and quality improvements reinforce each other.

## Talk Summary

### The accuracy asterisk on the capability curve

- Plausible ≠ correct is an enterprise-wide crisis: KPMG and EY retracting
  hallucinated reports, law firms sanctioned over fabricated citations.
- METR time-horizon data: the latest Mythos-class model completes ~16–18-hour
  human tasks — **at a 50% success rate**. Demand 80% accuracy and the horizon
  drops to ~3.5 hours. A customer CTO: "I would still put someone who gave me
  80% accurate information on a performance review."
- Sonar's benchmarking (4,000+ problems): state-of-the-art models score very
  well on functional correctness but still produce high, variable complexity,
  plus bugs and security issues — and that output feeds agentic workflows.
- Carnegie Mellon study: AI coding yields a 3–5x velocity boost that
  **dissipates within ~3 months**, because security, reliability, and
  maintainability issues rise in parallel — technical debt accumulates as fast
  as the code. "Code is provable, but software is not": large codebases are
  messy, dependency-ridden, and already indebted.

### The AC/DC framework: guide, verify, solve

**Guide = context + constraints, deliberately separated.**
Context: help agents understand the codebase — architectural awareness,
semantic navigation maps. Constraints: coding standards, allowed/forbidden
dependencies, guardrails, and *intended* (not just existing) architecture.
This is preemptive verification — less to verify, less to fix — and cut token
consumption 30%+ in their testing: you're making the agent's life easier.

**Verify = zero-trust, multi-layered.**
Zero-trust: every model has biases and a personality, so use *different*
models and techniques to check each other. Multi-layered: combine
**algorithmic** verification (data flows, control flows, known patterns,
secrets) with **agentic** verification (intent, business logic, unknown
unknowns). Customers doing both report 44% fewer AI-derived production
outages.

**Solve = verified code maintenance.**
Technical debt explodes alongside generated code; control it with an active
maintenance discipline (remediation agents, cleanup cadence). Agents care
about clean code as much as humans: the same agentic task on a cleaned
codebase uses materially fewer tokens and reasoning — a compounding effect.

### Three loops, deliberately designed

1. **Agentic loop** — in-loop verification *while* the agent works, with
   context and constraints supplied during generation.
2. **CI verification loop** — agent-powered PR review at much higher velocity,
   evals, quality gates.
3. **Code-maintenance loop** — keeping the codebase clean so future agent
   work stays cheap.

The loops compound: one large bank measured a 92% reduction in issues with
guide-verify-solve inside the agentic loops — not per-loop, but compounding
over minutes and hours of problem solving.

## The Loom Lens: You Already Built AC/DC

Loom is a more complete implementation of this framework than the one Sonar
sells; the talk's main value is external validation plus two sharpening
points.

The mapping is almost one-to-one:

| AC/DC | Loom |
|---|---|
| Guide: context | CONTEXT.md, domain model, ubiquitous language |
| Guide: constraints | rules files, lint-rules, skills — including *intended* architecture |
| Verify: algorithmic | lint-rules (boundaries, purity) |
| Verify: agentic | review panels, refutation verifiers, spec-check (Sonar's "intent/business logic" layer, literally) |
| Solve: maintenance | distill, deepen |
| Agentic loop | wave implementation + hooks |
| CI verification loop | wave-gate, review-pr |
| Maintenance loop | distill/deepen cadence |

The CMU three-month dissipation curve is the strongest argument for loom's
overhead: the discipline isn't a tax on velocity, it's what stops the 3–5x
boost from evaporating.

Two things worth taking:

1. **Zero-trust model diversity as an enforced property.** Already held as a
   pattern (different vendors for coding vs. review); Sonar upgrades it from
   preference to principle. Loom's verifier panels could *require* that
   refutation lenses run on a different model than the implementer — making
   self-review bias structurally impossible rather than conventionally
   avoided.
2. **In-loop verification, not just gate verification.** Loom verifies at
   wave gates; Sonar argues the agentic loop needs verification *while the
   agent works* (the 92%-compounding claim rests on this). Loom's hooks are
   the mechanism — run lint-rules on every edit, not only at the gate.

## The Fugue Lens: Guide-Side Validation, One New Idea

Fugue's runtime verification (the door/ledger) is orthogonal to this talk —
but fugue *as a codebase agents work on* is squarely in scope, and its
authoring design is Sonar's "guide" thesis implemented:

- `fugue new` scaffolds lint-clean DAGs → constraints ahead of generation
- the DAG type system makes illegal graphs unrepresentable → constraint
- `fugue lint` → algorithmic verification
- ten golden examples + docs → agent context

Sonar's token-economics finding — clean codebases materially cut tokens per
agent task — is empirical support for fugue's costly-looking hygiene (3,097
green tests, `check:docs`, lint-clean examples): that discipline is literally
cheaper agent operation.

**The new idea: zero-trust applies to fugue's runtime judges too.** When
fugue grows LLM-judge evaluator nodes (see eval-calibration.md), "every model
has biases" says the judge should run on a *different model* than the
generating node. Fugue's LM-adapter abstraction makes cross-provider judge
routing a config concern — a capability LangGraph-style stacks don't give you
for free.

## The Meta-Point

- **Coyle**: move invariants out of prose into deterministic checkers (what
  to check).
- **Lyft**: move trust in probabilistic checkers onto measured
  precision/recall (how to trust the checkers).
- **Sonar**: put the checks in every loop so they compound (where the checks
  live).

A verified system needs all three: symbolic invariants, calibrated judges,
and loop placement that makes quality self-reinforcing instead of
self-eroding.

## Notable Quotes

- "Code is provable, but software is not."
- "You're building technical debt as quickly as you are generating the code —
  or maybe even more quickly."
- "Every model has biases… so let's use different models and different
  techniques to make sure your code is safe."
- "Do agents care about clean code? They absolutely do — because the agents
  have to understand the codebase if they're going to operate on it."

## References

- Talk: https://youtu.be/VrpEyglYgeU (Tariq Shaukat, AI Engineer)
- METR time-horizon benchmarks (task length vs. success rate)
- Carnegie Mellon study on AI coding productivity dissipation
- Sonar Vortex (guide/context product), SonarQube ecosystem
