# Agent Optimization: Evals as Gradient, Not Just Gate

*Learned: August 2026*
*Source: [Agent Optimization with Pydantic AI: GEPA, Evals, Feedback Loops — Samuel Colvin, Pydantic](https://youtu.be/A48uhxfxbsM) (AI Engineer conference workshop)*
*Fourth in the verification series: [neuro-symbolic-guardrails.md](neuro-symbolic-guardrails.md)
(what to check), [eval-calibration.md](eval-calibration.md) (how to trust the checkers),
[verification-loops.md](verification-loops.md) (where the checks live) — and this one: checks as
the fitness function an optimizer climbs. The loop actually closing.*

**Bias note:** vendor workshop by Pydantic's CEO, but candid — he demos the "Heath Robinson"
manual wiring rather than the paid magic, calls AI observability "a feature, not a category,"
and flags Logfire's rough edges live.

## The Thesis

Once an eval exists and is calibrated, it stops being merely a launch gate and
becomes a fitness function: GEPA-style optimizers breed better prompts (and
model choices, and harness configs) against it automatically. Pair that with
typed runtime-managed configuration and you get the prototype of self-driving
agent optimization — hill-climbing production behavior without redeploys.

## Talk Summary

### GEPA in brief

GEPA (**ge**netic-**Pa**reto, by Lakshya Agrawal, first-year Berkeley PhD;
usable inside or outside DSPy) optimizes a string — a text prompt or JSON
holding anything. A proposer agent (here: a Pydantic AI agent optimizing a
Pydantic AI agent) generates a candidate, an eval scores it, and new
candidates are bred from components of the Pareto frontier — "breeding
racehorses." Colvin's honesty: state of the art, yet "not actually that
groundbreaking" relative to the models themselves. Warts: not type-safe,
sync-only (fresh HTTP client per proposer run).

With multiple keys in GEPA's dict, the proposer selects and combines rather
than free-writes — e.g. "choose the best 20 sentences of these 200" (the DSPy
idiom) — which also fixes the prompt-bloat problem where freeform proposers
(GPT-5-mini in his test) produce enormous prompts.

### The demo: UK political dynasties

Task: extract *ancestral* political relations for all 650 UK MPs from
Wikipedia HTML (structured output, list of typed relations). Models reliably
find relations but can't resist including spouses/siblings — the constraint
the optimizer must learn. Golden dataset generated with Opus 4.6,
hand-checked. Custom **deterministic evaluator** against the golden set.

Results: simple prompt ~87% → hand-written expert prompt ~92% →
GEPA-optimized ~96.7% (at the cost of a verbose prompt).

### Deterministic evaluators beat LLM-as-judge

Comparing against a golden set is "much better" than a judge — LLM-as-judge
is "the lunatics running the asylum." No golden set? Run the code and see if
it fails; or capture implicit user feedback — the best signal is what the
user did next ("you idiot, try again" vs. silence; the Google dwell-time
trick). Thumbs-up buttons go unclicked. Privacy-bound shops (legal tech:
Harvey, Legora) exfiltrate only categorical grades, never content. Reduce
variance by rerunning cases many times (hedge funds: ~$20k/night on eval
reruns).

### Where optimization pays — and where it doesn't

- **Pays**: small/fast/cheap models on narrow, high-volume tasks. Shopify
  replaced whole-site GPT-5 classification with an agentic Qwen setup plus
  GEPA-optimized prompts: **$5M/year → ~$73k/year**, performance improved.
  And private data ("98% of data is private"): choosing which domain context
  goes into the prompt is exactly what optimization does well.
- **Doesn't**: frontier models on public data mostly just get it right. Broad
  open-ended agents are the hardest target — coding agents' trajectory space
  is too sparse; over-optimizing 5,000 test cases overfits a drop in the
  ocean. Boris Chen on Claude Code: "mostly vibes."

### The failure modes are classic ML

- **Overfitting**: an attendee's optimized prompt explicitly excluded aunts
  and uncles — the training subset lacked them, so exclusion scored well. You
  need data covering the space and a held-out validation split (~2x data).
- **Model-specificity**: optimized prompts bind to one model; the next
  release can invalidate the work. This is why most teams skip optimization
  ("ask your coding agent 'does this look good?', eyeball it, ship it") —
  rational unless volume is huge (the private-equity 200M-invoices case).
- **Search space beyond prompts**: model choice, compaction strategy, tool
  registration, code mode — Pydantic's roadmap is optimizing across all of
  it.

### Managed variables: typed config with rollout control

Any Pydantic model (e.g. instructions + model + max_tokens) lives in Logfire,
is pulled at runtime, and supports percentage-based targeting (A/B) — built
on the **OpenFeature** open standard. Demo: switching a production agent's
reply language and provider live, no redeploy. The end state Pydantic is
building: evals + optimizer autonomously hill-climbing production variables
("self-driving managed variables").

## The Fugue Lens: Gate Becomes Gradient, Config Grows a Second Channel

1. **GEPA composes directly with the `fugue eval` primitive** (proposed in
   eval-calibration.md). GEPA needs a mutable string/dict and a scoring
   function; LLM-node prompt templates are the former, an eval run over a
   golden dataset is the latter. The eval harness pays for itself twice:
   deploy gate, then fitness function for every `createLlmNode` prompt. With
   multi-key dicts the search space extends to per-node model choice — and
   the Shopify result ($5M → $73k by decomposing one big-model call into a
   pipeline of small optimized models) is a fugue-shaped DAG discovered by
   hand. Fugue makes that architecture declarable; GEPA makes it tunable.
2. **Managed variables, ported with a guardrail.** A typed variable (zod
   schema in fugue's world) pulled at runtime with percentage targeting, on
   OpenFeature (TS SDKs exist), would let operators tune prompts/models per
   node without the host's git-sync redeploy. **Tension**: a runtime variable
   channel is a production mutation path that bypasses the launch gate from
   verification-loops.md. Structural fix: variable updates must pass the same
   eval gate as code deploys before targeting reaches 100% — otherwise
   Colvin's convenience quietly undoes Sonar's and Lyft's discipline.
3. **Independent validation of fugue's judge stance**: deterministic
   evaluators over golden sets beat LLM-as-judge wherever determinism can
   reach — guardrail nodes first, calibrated judges only beyond that.

## The Loom Lens: Optimize the Narrow Judges, Leave the Broad Agents to Vibes

1. **The GEPA sweet spot inside loom is the judges, not the implementers.**
   Broad open-ended agents (coding agents — "mostly vibes") are the hardest
   optimization target; narrow binary classifiers are the best. Loom's
   implementer agents are the former; its refutation lenses, spec-check, and
   adjudicators are the latter — GEPA's home turf. Once the calibration
   corpus exists (labeled findings: real/noise), the pipeline is mechanical:
   corpus as golden set, panel precision/recall as fitness, GEPA breeding
   verifier prompts. The regression suite from eval-calibration.md becomes a
   gradient.
2. **The aunts-and-uncles failure is the exact trap.** Optimizing refutation
   prompts on a small corpus teaches the optimizer to dismiss whatever bug
   categories the corpus underrepresents — for a *verifier*, the worst
   possible failure (silently killing real findings). Non-negotiables:
   category coverage in the corpus, and a held-out validation split the
   optimizer never sees.
3. **Model-specificity compounds with zero-trust diversity.** Optimized
   prompts bind to a model; multi-model panels (verification-loops.md) mean
   each lens×model pair needs its own optimization, and every model swap —
   including the wait-one-month adoption policy — re-opens it. Argument for
   keeping judge prompts simple and rule-anchored, or automating
   re-optimization so a model bump triggers a GEPA run against the fixed
   corpus.
4. **Managed variables are the pattern loom correctly rejects.** Loom's
   prompts and rules are files in git — versioned, reviewed, diffable. Right
   call for dev-time tooling, where "deploy" is a commit and auditability
   beats hot-swapping. Runtime hot-swap belongs in fugue's world; keep the
   contrast deliberate.

## The Meta-Point (Series of Four)

- **Coyle**: move invariants out of prose into deterministic checkers.
- **Lyft**: move trust in probabilistic checkers onto measured
  precision/recall.
- **Sonar**: put the checks in every loop so they compound.
- **Colvin**: once a check is trusted, use it as a fitness function —
  the eval graduates from gate to gradient, and improvement becomes
  automatic.

## Notable Quotes

- "LLM-as-a-judge is effectively the lunatics running the asylum."
- "This optimization technique, whilst the state of the art, is not actually
  that groundbreaking… ask an agent to generate a new prompt, if it does
  better, take bits of it, keep doing that."
- "Optimization matters way more where you have large amounts of private
  data."
- "The ultimate eval is wait 40 years and see when they died." (on proxy
  metrics)
- "If you go and ask Boris Chen how he works on Claude Code, he says mostly
  vibes."

## References

- Talk: https://youtu.be/A48uhxfxbsM (Samuel Colvin, AI Engineer)
- GEPA — Lakshya Agrawal, UC Berkeley; usable standalone or within DSPy
- Pydantic AI, Logfire (evals, managed variables, annotation), Pydantic AI
  Gateway
- OpenFeature — open standard under Logfire managed variables
- Shopify GEPA case study ($5M → $73k/year)
- Demo repo: `github.com/pydantic/talks` → `2026_04_ai_engineer`
