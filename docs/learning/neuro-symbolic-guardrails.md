# Neuro-Symbolic Guardrails for Agentic Systems

*Learned: August 2026*
*Source: [Why Agentic Systems Need Ontologies — Frank Coyle, UC Berkeley](https://youtu.be/Sir59K8ZDPU) (AI Engineer conference, ~20 min)*
*First of a series of four: this doc says what to check (domain invariants, deterministically);
[eval-calibration.md](eval-calibration.md) says how to trust the checkers (calibrate judges like
classifiers); [verification-loops.md](verification-loops.md) says where the checks live (every loop
of the development cycle, so they compound); [agent-optimization.md](agent-optimization.md) turns
trusted checks into fitness functions (gate becomes gradient).*

## The Thesis

LLM-driven agents are probabilistic by nature — hallucination is the feature, not
the bug ("we imagine things that may not exist, and then we turn them into
reality"). So agents need formal, deterministic guardrails: ontologies —
knowledge graphs plus reasoning layers (RDFS/OWL) — that validate agent output
before anything commits.

Coyle's slogan: **"Pydantic at the door, ontology at the ledger, pure agents."**

- **Door**: type/schema validation on inputs and tool parameters.
- **Ledger**: semantic validation of results against a domain model — the
  cross-entity, cross-history invariants no payload schema can see.
- **Pure agents**: no side effects until validation passes.

This is neuro-symbolic AI: probabilistic LLMs paired with symbolic
representations. Effectively a return to 1980s expert systems, but with the
scaling problem solved by the neural half.

## Talk Summary

### Ontologies in brief

An ontology is a graph of entities, relationships, and properties — Gruber
(1993): "a formal specification of a shared conceptualization." Graph databases
won over relational tables here because you can attach new entities/properties
without schema rewrites. Build top-down (domain experts enumerate entities —
the 1980s expert-systems approach, which failed to scale and triggered an AI
winter) or bottom-up (mine entities from real interactions). Reuse existing
ontologies: schema.org, FOAF (social), Dublin Core (publications), DBpedia
(underlies Wikipedia).

### Inference and constraints (RDFS / OWL)

The reasoning layers sit *beside* the graph:

- **Domain/range** (RDFS): "teaches has domain Teacher, range Student" —
  "Bob teaches Scooter" now infers Bob is a teacher (and a person), Scooter a
  student.
- **Transitive properties** (OWL): ancestor-of chains propagate automatically.
- **Functional properties** (OWL): "has-father" is unique — two names for the
  father must denote the same individual.
- **Disjoint classes** (OWL): Customer and SupportRep can never be the same
  entity.

### Why loops need this

Böhm–Jacopini (1966): sequence + conditionals + iteration = Turing complete.
Agent loops deliver that last piece — and with it the failure modes: loops
break, drift as agents talk to each other, and burn tokens. So surround the
loop with checks.

The validated agent loop (his Claude/Python example): LLM proposes a tool call
(it can't execute anything — "all it can do is give us the next word with high
probability") → check `stop_reason` → harness runs the tool → **pass the result
through an ontology-backed validator** → accept, retry with the LLM, or
escalate to a human.

### Errors ontologies catch that prompts can't reliably

- A second refund on the same order (functional property / ledger history).
- A payout routed to a support rep instead of the buyer (disjoint classes).
- Hallucinated enum values like "probably shipped" when only
  paid/shipped/refunded are legal (value restrictions).

All awkward to enforce in natural-language prompts; trivial for a reasoner.

### A correction worth knowing: SHACL, not OWL, for validation

OWL reasoners are **open-world**: given a functional-property violation ("Bob
is the father, BB is the father"), an OWL reasoner *infers Bob = BB* rather
than raising an error. **SHACL** is the W3C validation counterpart —
closed-world, produces violation reports — which is what a guardrail actually
wants. TypeScript ecosystem: `rdf-validate-shacl` over an N3.js store, or
Oxigraph's WASM bindings for a fast in-process triple store.

## How This Maps to Fugue and Loom

Fugue and loom each already implement about half of Coyle's picture — but
*different* halves. Both already embody "pure agents, no side effects" (fugue's
functional core and capability brokering; loom's FC/IS rules). The genuinely
new import in both cases is the inference/constraint layer.

### Fugue: the door is built, the ledger is missing

Fugue guards *runtime data* flowing through a DAG. Every node edge carries a
zod `inputSchema`/`outputSchema`, results are `Result` types, IDs are branded,
guardrail nodes are pure, and effects go through identity-scoped capabilities.
That's "Pydantic at the door" done more rigorously than Coyle's sketch.

What zod *cannot* express is the ledger: cross-entity, cross-history
constraints. "Status ∈ {paid, shipped, refunded}" is a zod enum — already
covered. "No second refund on the same order" and "payout recipient must not
be a support rep" span multiple entities and prior state; no per-node payload
schema can see them. Fugue's branded IDs are already a micro-ontology (entity
typing at compile time); the gap is only the *relational* invariants between
them.

**What to build**: a domain-invariant guardrail node (or capability adapter,
like `adapter-pg`) that runs after LLM nodes and before any capability write —
literally "ontology at the ledger."

1. **Standards route**: project node outputs to RDF triples, validate against
   SHACL shapes (`rdf-validate-shacl` + N3.js, or Oxigraph WASM), return
   `GuardrailResult`.
2. **Pragmatic 80/20, no RDF** — given `adapter-pg` already exists:
   - functional properties → unique/exclusion constraints
   - disjoint classes → branded types + runtime membership check
   - transitive queries → recursive CTEs
   - "no second refund" → ledger-table check
   That's Coyle's whole error catalog in infrastructure fugue already ships —
   an ontology in semantics if not in syntax. **Start here**; reach for SHACL
   only if constraints multiply enough that declaring them as data beats
   coding them.

### Loom: has an ontology, but checks it probabilistically

Loom guards *development artifacts* flowing through a pipeline. Its symbolic
layer already exists: the rules files, the lint-rules (boundary/purity checks —
genuinely symbolic), and CONTEXT.md's domain model and ubiquitous language.
But *enforcement* of the domain model is mostly LLM-judged: grill stress-tests
plans against CONTEXT.md, spec-check detects drift, review-verifier panels
refute findings — all agents reading prose and opining. That's a probabilistic
system checking probabilistic output; Coyle's argument is precisely that the
checker should be deterministic.

**What to build**: compile CONTEXT.md's domain model into something
machine-checkable, shifting checks from agent judgment to the linter.

1. **Formalize the ubiquitous language** — entities, relationships, legal
   states, disjointness — as a structured artifact (YAML/JSON schema next to
   CONTEXT.md). Grill and spec-check then diff plans/code against it
   deterministically for the mechanical parts (undeclared entity names,
   illegal state values, terminology drift), reserving LLM judgment for the
   semantic parts. That's the neuro-symbolic split.
2. **Extend lint-rules from code structure to domain structure**: with a
   declared state machine per aggregate, the linter can verify ADTs make
   illegal transitions unrepresentable — the "illegal states impossible"
   standard audited symbolically instead of by a reviewer agent.
3. **Wave scheduling has a disjointness constraint hiding in it**: parallel
   tasks in a wave must own disjoint file sets — exactly an OWL
   disjoint-property check. Decompose-agent already emits pure JSON task
   graphs, so validating them is cheap, deterministic, and cheaper than
   discovering the collision at merge time.

## The Meta-Point

Fugue and loom are both agent loops in Coyle's sense (propose → check →
accept/retry/escalate, with HITL gates), operating on different substrates.
In both, the highest-leverage upgrade is the same move: take invariants that
currently live in prose (CONTEXT.md, prompts) or in per-payload schemas, and
move them into a deterministic cross-entity checker that runs before anything
commits.

## Notable Quotes

- "Nothing is a mistake. There is no win, there's no fail. There's only make."
  (Sister Corita Kent, via John Cage — Coyle's opening philosophy)
- "People worry about hallucinations, but that's the feature."
- "LLMs can't do anything. All they can do is give us the next word with a
  high probability."
- "Pydantic at the door, ontology at the ledger."

## References

- Talk: https://youtu.be/Sir59K8ZDPU (Frank Coyle, AI Engineer)
- Gruber (1993) — ontology as "formal specification of a shared conceptualization"
- Böhm–Jacopini (1966) — structured program theorem
- Existing ontologies: schema.org, FOAF, Dublin Core, DBpedia
- Validation tech: SHACL (`rdf-validate-shacl`), N3.js, Oxigraph (WASM)
- Speaker's site: codesupreme.ai
