# Eval Calibration: Validate the Validators

*Learned: August 2026*
*Source: [Build Evals That Actually Matter — Nick Ung & Akshay Sharma, Lyft](https://youtu.be/3z2uT5aDx_Y) (AI Engineer conference)*
*Second of a series of four: [neuro-symbolic-guardrails.md](neuro-symbolic-guardrails.md) says what
to check (domain invariants, deterministically); this doc says how to trust the checkers (calibrate
judges like classifiers); [verification-loops.md](verification-loops.md) says where the checks live
(every loop of the development cycle, so they compound); [agent-optimization.md](agent-optimization.md)
turns trusted checks into fitness functions (gate becomes gradient). Together: schema at the door,
symbolic invariants at the ledger, validated judges above both.*

## The Thesis

Evals fail for three reasons: scores don't gate anything, LLM judges are generic
and unvalidated, and nobody looks at the data. The fix is to treat the eval
pipeline with the same rigor as classical ML: offline evaluation as a launch
gate, judges treated as classifiers measured against hand-labeled ground truth,
and a continuous error-analysis loop feeding insights back into the agent.

Lyft's context: ~2 years building a multi-agent customer-support system
(LangGraph), with offline simulation gating what ships and online graders plus
human-in-the-loop error analysis running in production.

## Talk Summary

### Offline eval is a launch gate, not a dashboard

Never use live users as test data. Simulate complete multi-turn conversations —
agent LLM vs. user LLM, per **TauBench** (Sierra AI) — with defined user intent,
world state, and persona. Require pass criteria before production, exactly as
offline eval gates classical ML model deploys.

### Synthetic data must come from production

Don't prompt an LLM for "50 test queries." Sample real production interactions
and mutate them to cover golden paths and edge cases.

### Frontier models are too nice to play users

Their first simulator produced patient, articulate users and a 90%+ pass rate —
too good to be true, and it was. Real users are terse, impatient, already
frustrated. They **fine-tuned the user LLM on real Lyft verbatims until the
eval score went down** (same approach as Microsoft's UserLM paper): a harder
eval is the honest one. Personas ground it further: bypasser (escalate
immediately, no chance for the AI), refund-seeker, AI-skeptic.

### Generic judge metrics are useless

Pre-built metrics (DeepEval's helpfulness, naturalness, toxicity, conciseness
scores) are baselines at best — "if response helpfulness is 0.5, what do we do
with it?" Replace with **binary pass/fail rubrics co-designed with domain
experts and tied to business outcomes**. Example, their education rubric:
*fail* if the agent kept trying to educate when it should have escalated, or
escalated without attempting to educate; *pass* if the behavior matched policy.
Binary outcomes are easy to calibrate and make failures systematically
analyzable.

### Validate the validators

Treat the LLM judge as a classifier:

1. Hand-label ~100 examples pass/fail.
2. Split train/dev/test — train supplies few-shot examples for the judge
   prompt, dev is for prompt iteration, test catches overfitting.
3. Report the judge's **precision/recall against human labels**. That report is
   what makes the judge trustworthy, not the judge's own confidence.

Accept **criteria drift**: you discover evaluation criteria by grading data,
and your sense of quality evolves with more examples. Rubrics are co-developed
with observation, not fixed upfront — evaluators and criteria evolve together.

### Every score needs an interval

84% vs. 88% on 50 traces proves nothing. Report confidence intervals; reserve
heavy statistical rigor for decisions that matter (ship gates, leadership
numbers), but never present point estimates as conclusions.

### Error analysis is a continuous loop

Read raw traces → pinpoint failure modes → **keep only metrics that change a
decision** → form a fresh premise → repeat, weekly or biweekly. Not a one-off
audit. Root anti-pattern: ignoring the data. No data → no labels → no
validated judges → no trustworthy pipeline. Tracing infrastructure (LangSmith,
LangFuse: full graph execution, tool calls, tokens, latency) plus **annotation
queues** so domain experts can label without reading raw JSON.

### Eval harness as infrastructure

Their current pain: evals as scattered notebook scripts — not repeatable.
Target: a config-driven harness (YAML, editable by analysts, not just
engineers) built on primitives — **task, dataset, persona, LM adapter,
evaluator** — parallelized, and runnable at every gate: local dev, pre-commit,
CI/CD regression and acceptance suites. Define once, run indefinitely.

### Three channels for closing the loop

- **Model learning** — post-training, fine-tuning, reward modeling / RL.
- **Context learning** — documents, stored memories, tool outputs.
- **Harness learning** — system prompts, tool schemas, control flow, routing,
  retries.

## The Fugue Lens: Eval as a First-Class Primitive

Fugue is exactly the kind of production system this talk gates. Its
deterministic evaluators already exist — zod schemas and guardrail nodes are
Lyft's "code assertion" evaluator category. Missing is the probabilistic
quality axis: a zod-valid LLM node output can still be a *bad* summary, and
nothing in the framework measures that.

1. **Lyft's confessed pain is fugue's warning.** Their evals are scattered
   notebook scripts; fugue's eval story is a Python harness inside one example
   app (`apps/customer-summary`) rather than a framework concern. The fix maps
   onto fugue's design language: a **`fugue eval` CLI verb beside
   `fugue lint`** — lint checks graph shape deterministically, eval runs a
   dataset through the DAG and scores LLM node outputs. Lyft's harness
   primitives (task, dataset, persona, adapter, evaluator) are one-to-one with
   fugue's declarative, config-driven style; YAML suites editable by
   non-engineers fit the `fugue.yaml` contract.
2. **The launch gate belongs in the host's deploy path.** The host already
   git-syncs DAG registrations; the deploy contract could carry eval-gate
   criteria so a DAG version that regresses on its suite never goes live —
   offline eval as CI gate, the "score must gate something" rule.
3. **Close the loop from traces.** The host has observability; missing is
   Lyft's cycle: sample production traces into offline datasets, add an
   annotation-queue surface so domain experts label pass/fail without reading
   JSON, and use those labels to compute precision/recall for any LLM-judge
   evaluator before trusting it in a gate.
4. **Judges are nodes too.** An LLM-judge evaluator slots into fugue as a node
   type with `Result`-typed output — but ships with a labeled validation set
   and measured precision/recall, and eval reports carry confidence intervals
   before anyone gates on 84%-vs-88% over 50 traces.

## The Loom Lens: A Building Full of Unvalidated Judges

Loom's quality architecture *is* LLM-as-judge: review-verifier refutation
panels, arch-judge candidate scoring, wave-gate, spec-check drift detection.
The critique lands directly — these judges gate real decisions (findings die
or survive, waves pass or fail), but nothing measures whether the judges are
any good.

1. **Loom already got two things right by Lyft's standards**: verdicts are
   binary (refuted/not-refuted, pass/fail — the calibratable shape), and
   scores gate something (wave-gate, adjudication). Missing is the classifier
   treatment: **hand-label ~100 past review findings as real/noise, run the
   refutation panels against them, report panel precision/recall.** Until
   then, "the panel refuted it" is an uncalibrated instrument reading. Loom's
   `calibration/` directory is where the labeled corpus and judge scorecards
   belong, if it doesn't hold exactly this already.
2. **Criteria drift is the rules-file lifecycle.** Rules files and reviewer
   rubrics are the judge criteria; criteria must be co-developed with observed
   data. Concrete loop: track which findings led to fixes vs. were dismissed,
   feed that error analysis back into rules and verifier prompts on a cadence
   — continuous, not a one-off audit.
3. **Regression-test the agents themselves.** Hooks and lint-rules are loom's
   deterministic pre-commit layer; the missing piece is an eval suite *for
   loom's prompts*: recorded scenarios (a spec, a diff, a task graph) with
   expected judgments, re-run whenever an agent prompt or model changes.
   Otherwise a prompt tweak to review-verifier silently changes what ships.
4. **The statistics bite hardest here**, because panels vote in small numbers
   (2-of-3 lenses). Fine for per-finding decisions; but "the new reviewer
   prompt catches more bugs" needs a labeled sample large enough to separate
   signal from noise before it justifies changing the pipeline.

## The Meta-Point

Coyle moves invariants out of prose into deterministic checkers; Lyft moves
trust in probabilistic checkers from vibes onto measured precision/recall.
For fugue: eval becomes a framework primitive with a deploy gate. For loom:
the judges that already gate everything finally get judged.

## Notable Quotes

- "We don't want to use our live users as test data for our AI agents."
- "Our LLM user sounds almost too nice… 90-plus pass rate — this almost
  sounds too good to be true, and it indeed is."
- "If the metrics are just scores, we don't know what to do with them."
- "Every score needs an interval."
- "If you don't look at the data, you won't be able to create meaningful
  criteria."

## References

- Talk: https://youtu.be/3z2uT5aDx_Y (Nick Ung & Akshay Sharma, AI Engineer)
- TauBench (Sierra AI) — multi-turn agent/user simulation benchmark
- Microsoft UserLM paper — fine-tuning user simulators until eval scores drop
- DeepEval — pre-built metrics (baseline only), LangSmith / LangFuse —
  tracing + annotation queues, LangGraph — their agent framework
