# Frozen task brief — Fugue bounded runtime-width fan-out

This brief is an immutable benchmark input. Accepted ADRs and `CONTEXT.md` in
the pinned Fugue checkout are normative. Research spikes and old plans are
context, not authority.

---

Add bounded runtime-width fan-out to Fugue.

Introduce a map/scatter-gather primitive that receives a runtime collection
from an upstream node, executes one statically declared worker computation per
item, and exposes one ordered gathered result to the static DAG.

The feature must preserve Fugue's type safety, capability validation, spend
enforcement, bounded concurrency, deterministic routing, durable crash-resume,
freshness guarantees, tracing, authored-DAG workflow, and visualization.

Runtime width must not generate source code or mutate DAG topology. The DAG
remains acyclic and statically authored. The first release maps one statically
declared worker computation, not a child subgraph.

Plan the complete production change through brainstorm, specification,
architecture, plan alignment, and decomposition. Stop immediately before Wave
1 implementation: `current_phase` may be `execute` and `current_wave` must be
`1`, but every task must remain `pending`, `executing_tasks` must be empty, and
no implementation, test, review, ADR-writing, or wave-gate child may run.

Do not implement anything. Do not create an issue, push a branch, update
`CONTEXT.md`, or write outside `.claude/`.

## Product decisions

- An empty collection succeeds with an empty gathered result and no worker effects.
- Gathered results are always in input-index order, never completion order.
- Equal item values remain distinct instances because identity is index-based.
- A positive integer cardinality ceiling (`maxItems`, name not prescribed) is required. An oversized input fails before any worker starts.
- A positive integer concurrency ceiling (`maxConcurrency`, name not prescribed) is independently required.
- Existing retry policy applies per item. An item that exhausts retries fails the map node; v1 has no best-effort partial-success mode.
- After terminal failure or cancellation, no new items are admitted. Active work receives the existing cancellation signal where supported.
- Successful item checkpoints survive failure and are not executed again on resume.
- Existing spend accounting remains authoritative. Do not invent speculative cost estimation.
- Worker capability requirements are validated before any item starts.
- Outgoing routing evaluates once, after successful gather, against the gathered output.
- Existing non-map checkpoint keys and behavior remain byte-compatible.
- Exact public API names are an architecture decision; observable semantics above are fixed.

## Scope

In scope: framework domain types, DAG validation/fingerprinting, scheduler and
state transitions, all checkpointer adapters, freshness/effect identity,
tracing, authored DAG parsing/code generation, describe/Mermaid output, exports,
documentation required by the implementation, and tests.

Out of scope: agent-call nodes, nested subgraphs, cross-node loops, quorum
voting, MCP, memory adapters, arbitrary expressions, dynamic source generation,
and unrelated host or UI work.
