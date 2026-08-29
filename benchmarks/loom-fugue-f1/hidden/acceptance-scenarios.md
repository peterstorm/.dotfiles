# Hidden acceptance scenarios — Fugue F1 map v1

These behavior-level scenarios calibrate semantic grading without imposing an
undisclosed TypeScript API. Every reference requirement appears in at least one
scenario tag.

## Definition and analysis

- **AS-001 — Static plate.** Given a valid map declaration, DAG analysis sees one static node and the same cycle/output rules as other nodes; runtime item count cannot change topology. [FR-001] [FR-002] [FR-029]
- **AS-002 — Invalid limits.** Zero, negative, fractional, non-finite, or unsafe cardinality/concurrency values fail while parsing the definition. [FR-003]
- **AS-003 — Parse before effects.** One malformed item in an otherwise valid collection causes failure before capability acquisition or worker invocation. [FR-004] [FR-008]
- **AS-004 — Fingerprint stability.** Equal definitions have equal fingerprints regardless of runtime values; worker/schema/limit/reference changes alter them; equivalent non-map DAGs retain their prior fingerprint. [FR-030] [FR-031]

## Scheduling and outcomes

- **AS-005 — Empty.** Empty input returns immutable empty output with no worker, spend, or effect call. [FR-005] [FR-007]
- **AS-006 — Ordered gather.** Workers for indices 2, 0, and 1 complete in that order; gathered output remains 0, 1, 2. [FR-005] [FR-010]
- **AS-007 — Duplicate values.** Two equal input values execute and checkpoint independently at indices 0 and 1. [FR-006]
- **AS-008 — Oversize preflight.** `maxItems + 1` items produce one typed failure and zero worker-side observations. [FR-008] [FR-027]
- **AS-009 — Concurrency property.** Across generated completion schedules and retries, observed active workers never exceed the declared ceiling. [FR-009] [FR-039]
- **AS-010 — Retry exhaustion.** One instance retries under existing policy, increments attempts, then fails the map; queued work is not admitted and no gathered output exists. [FR-011] [FR-012]
- **AS-011 — Cancellation.** Cancellation during active work aborts supported workers, launches no queued work, and cannot become empty success. [FR-013]
- **AS-012 — Spend authority.** Concurrent LLM workers still use the existing spend ledger/decorator and cannot bypass its fail-closed refusal. [FR-014] [FR-024]

## Persistence and effects

- **AS-013 — Address uniqueness.** Composite addresses differ by namespace, node, index, or attempt while an option-free address encodes exactly as before. [FR-015] [FR-016] [FR-022]
- **AS-014 — Adapter parity.** File, memory, and Redis save and load two indices and two attempts without collision under one Map Node. [FR-017] [FR-040]
- **AS-015 — Crash after completion.** A process crashes after indices 0 and 2 persist; resume reuses those outputs and invokes only remaining index 1. [FR-018] [FR-019] [FR-026]
- **AS-016 — Input disagreement.** Reordered, shortened, extended, or changed input refuses prior index checkpoints rather than attaching outputs to new items. [FR-020] [FR-021]
- **AS-017 — Corrupt durable state.** Invalid address, stale fingerprint/version, malformed output, or contradictory instance metadata returns a typed checkpoint failure. [FR-021] [FR-027]
- **AS-018 — Freshness isolation.** A witness from index 0 does not make index 1 fresh and cannot overwrite index 1's evidence. [FR-025] [FR-026]

## Capabilities, routing, and surfaces

- **AS-019 — Capability preflight.** A missing worker capability fails before the first worker; a valid map gives each instance the normal scoped context. [FR-023] [FR-024]
- **AS-020 — Route once.** All instances gather, the output schema parses, and exactly one outgoing routing decision observes the complete Gathered Output. [FR-028]
- **AS-021 — Authored round trip.** A closed field reference parses, code-generates deterministically, imports, lints, and describes; free-form expression text is rejected. [FR-032] [FR-033]
- **AS-022 — Description and Mermaid.** Describe exposes worker/reference/limits/schema and Mermaid emits one bounded plate rather than runtime boxes. [FR-034] [FR-035]
- **AS-023 — Trace identity.** Aggregate and instance traces can be correlated by parent/index/attempt while metrics use bounded labels. [FR-036]
- **AS-024 — Public language.** Exports, catalogues, CLI-facing docs, and examples consistently use Map Node, Map Instance, and Gathered Output. [FR-037]
- **AS-025 — Regression matrix.** Curated examples cover every named boundary and generated properties cover order, limits, determinism, immutability, and crash points before full and Redis suites pass. [FR-038] [FR-039] [FR-040]
