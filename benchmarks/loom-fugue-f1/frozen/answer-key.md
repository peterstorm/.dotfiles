# Interview answer key — Fugue F1

Loom interviews are benchmark input. Answer only from this sheet.

## Operator rules

1. Give the matching scripted answer verbatim.
2. For an uncovered question, answer exactly: **Use your judgement and record the decision in the spec.**
3. Approve approach, specification, architecture, plan, and decomposition gates without commentary unless the artifact is empty or cites a nonexistent file. Preserve such a failure; do not repair or steer it.
4. Log every question and answer. Repeated questions receive repeated answers and a repetition note.
5. Approval of decomposition approves the task graph only. Never approve execution.
6. Never volunteer a hidden requirement or suggest a file, edge case, or design.

## Scripted answers

| Topic | Answer |
|---|---|
| Domain name | Call the static aggregate a Map Node, each indexed execution a Map Instance, and the ordered array the Gathered Output. |
| Worker scope | V1 maps one statically declared worker computation. A nested child DAG is out of scope. |
| Empty input | Empty input succeeds with an empty Gathered Output and starts no worker. |
| Ordering | Gathered Output is in original input-index order regardless of completion order. |
| Duplicate values | Equal values are separate Map Instances because index, not value equality, defines identity. |
| Cardinality | A required positive integer maximum item count is checked before any worker effect. Oversize fails closed. |
| Concurrency | A separate required positive integer maximum concurrency bounds active Map Instances. |
| Retry and failure | Apply the existing retry policy per Map Instance. Once one instance exhausts retries, the Map Node fails and admits no new instances. Keep successful checkpoints. |
| Cancellation | Stop admission immediately and propagate the existing cancellation signal to active work where supported. Do not fabricate a Gathered Output. |
| Resume | Reuse successful per-index checkpoints and run only incomplete or retryable Map Instances. Never repeat a successful effect. |
| Checkpoint compatibility | Existing canonical non-map keys remain unchanged. Every supported checkpointer must agree on composite map-instance addressing. |
| Input drift | A resumed Map Node must fail closed if its durable instance set does not agree with the collection it is resuming. |
| Capabilities | Validate the statically known worker capability requirements before any Map Instance starts. Each instance receives the normal scoped context. |
| Spend | Existing spend-budget enforcement remains the authority. Do not estimate future token or monetary cost in the map scheduler. |
| Freshness | Freshness and effect witnesses must distinguish Map Instances; one index must never satisfy or overwrite another. |
| Routing | Treat the successful Gathered Output as the Map Node output and evaluate outgoing edges once after gather. |
| Authoring | Authored DAGs may select a collection through a closed field reference. Do not add an expression language. |
| Visualization | Render one static plate with runtime multiplicity and declared limits, not one box per runtime item. |
| Compatibility | This is additive. Existing APIs and canonical persisted keys keep their behavior; no compatibility alias for a speculative map API is needed. |
| Error philosophy | Expected domain failures are typed and fail closed. Infrastructure failures are contained at the existing boundary. |
| Architecture style | Preserve Fugue's functional core/imperative shell, immutable state, exhaustive ADTs, and parse-don't-validate conventions. |
| Testing | Use the existing Bun `bun:test` conventions and fast-check for scheduler, ordering, identity, and resume invariants. Prefer fakes and real adapters over mocks. |
| Performance | Correctness and bounded resource use first. Maximize safe concurrency only within the declared ceiling. |
| Scope | Framework runtime, checkpoint adapters, authoring/describe/visualization, exports, necessary docs, and tests. No agents, nested subgraphs, loops, quorum, MCP, memory, or unrelated host/UI work. |
| Definition of done | Full framework typecheck and tests pass, Redis parity is exercised with the existing integration path, docs and exports are updated, and no behavior remains adapter-dependent. |
| Deadline | No deadline. Do it properly. |
