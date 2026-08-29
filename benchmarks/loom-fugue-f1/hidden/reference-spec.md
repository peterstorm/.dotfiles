# Hidden reference specification — Fugue F1 map v1

This is a semantic grading oracle, not a model-visible contract. Arbitrary API
names are not requirements. A run receives credit when it plans equivalent
observable behavior and repository changes.

## Static domain model

- **FR-001** A Map Node is one statically authored DAG node whose runtime collection creates indexed Map Instances; runtime cardinality never mutates the DAG node/edge set.
- **FR-002** V1 declares exactly one worker computation, not a nested child DAG, arbitrary generated code, loop body, or quorum.
- **FR-003** Map limits are parsed positive safe integers before a valid definition can exist; cardinality and concurrency are distinct value objects or equivalent validated types.
- **FR-004** The map input contract parses the upstream value as a collection and parses every item before any worker effect begins.
- **FR-005** The successful Gathered Output is immutable, contains one parsed worker output per item, and is ordered by original index rather than completion time.
- **FR-006** Equal item values at different indices remain different Map Instances and cannot share identity or checkpoints.

## Admission and execution

- **FR-007** Empty input succeeds with an empty Gathered Output, admits no worker, spends nothing, and produces the normal successful Map Node transition.
- **FR-008** Input cardinality above the declared ceiling fails before capability acquisition, checkpoint writes, worker calls, or other worker effects.
- **FR-009** Active Map Instances never exceed the independent concurrency ceiling, including retries and completion races.
- **FR-010** Admission is deterministic and decoupled from result placement: completion order may vary while gathered order cannot.
- **FR-011** Worker execution reuses existing node retry policy per instance; each retry advances that instance's attempt identity.
- **FR-012** When one instance exhausts retries, the Map Node fails, admits no new instances, retains successful checkpoints, and emits no fabricated Gathered Output.
- **FR-013** Run cancellation stops admission and propagates the existing abort signal to active instances where supported; cancellation cannot be reported as empty success.
- **FR-014** Existing spend-budget enforcement remains the monetary authority for every worker capability call; the map scheduler adds no speculative cost estimator.

## Durable identity and resume

- **FR-015** A Map Instance checkpoint address carries namespace, parent Map Node ID, zero-based index, and attempt without casting the composite identity to canonical NodeId.
- **FR-016** Existing canonical calls that omit composite fields retain byte-identical keys and lookup behavior.
- **FR-017** File, in-memory, and Redis checkpointers implement the same composite-address contract; the plan explicitly discovers that in-memory and Redis ignore options at the pinned baseline.
- **FR-018** A successful instance persists its parsed output promptly enough that a crash after completion can resume without repeating its worker effect.
- **FR-019** Resume reconstructs the instance set, reuses successful outputs, and schedules only missing, cancelled, or retryable instances according to existing retry policy.
- **FR-020** Durable map state binds to an input-collection agreement value so reordered, replaced, truncated, or extended input cannot silently reuse index-addressed outputs.
- **FR-021** Malformed, stale-version, wrong-fingerprint, invalid-address, or input-disagreeing durable state fails closed through Fugue's typed checkpoint errors.
- **FR-022** Attempts never overwrite evidence from another index or earlier attempt; cleanup/retention policy remains explicit and compatible with forensic evidence.

## Capability, effect, and freshness discipline

- **FR-023** The statically known union of worker capability requirements is validated before any instance starts.
- **FR-024** Every instance receives the normal run-scoped capability context; a map cannot bypass provider, identity, budget, or cancellation decorators.
- **FR-025** Freshness and effect-witness keys include Map Instance identity, so one index cannot satisfy or overwrite another index's proof.
- **FR-026** Resume never repeats a successful externally visible effect solely because a sibling failed or the process crashed.
- **FR-027** Expected map-domain failures are explicit ADT members handled exhaustively; infrastructure exceptions remain contained at existing shell/adapter boundaries.

## Static DAG integration

- **FR-028** The Map Node becomes successful only after all required instances succeed and gather validates; outgoing conditional routing evaluates once against that Gathered Output.
- **FR-029** DAG analysis treats the map as a static node and preserves cycle checks, dependency validation, output-node rules, and wave resolution for the authored graph.
- **FR-030** The DAG fingerprint includes the static map contract, worker identity/schema, limits, and authored collection reference, but excludes runtime item values and runtime cardinality.
- **FR-031** Existing non-map DAG fingerprints and execution behavior remain unchanged.

## Authoring, describe, and observability

- **FR-032** AuthoredDag has a closed, schema-validated field-reference representation for selecting the runtime collection and does not admit expressions or executable text.
- **FR-033** Deterministic code generation emits the static map declaration, worker definition, limits, schemas, and field reference and survives the existing lint/describe gauntlet.
- **FR-034** Describe exposes the map shape, worker summary, declared cardinality/concurrency limits, collection reference, and gathered schema without materializing runtime instances.
- **FR-035** Mermaid renders one plate/multiplicity annotation connected as one static node, not one box per item.
- **FR-036** Aggregate and per-instance trace events are distinguishable and carry parent node ID plus index and attempt without unbounded metric-label cardinality.
- **FR-037** Public exports, capability/shape catalogues, CLI help where applicable, and user documentation use one Map Node/Map Instance/Gathered Output vocabulary.

## Verification and delivery

- **FR-038** Example tests cover empty, singleton, duplicate values, exact/over cardinality, out-of-order completion, retry exhaustion, cancellation, input drift, and routing after gather.
- **FR-039** Fast-check properties prove gathered order, concurrency bounds, deterministic admission/state transitions, immutable outputs, and crash-resume equivalence across generated item lists and crash points.
- **FR-040** Shared checkpointer contract tests cover canonical and composite behavior for file, in-memory, and Redis; final evidence includes framework typecheck/full tests and the existing Redis integration path.
