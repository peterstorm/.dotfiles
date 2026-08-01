# Architecture Rules

## Functional Core / Imperative Shell

- **Core modules** (`src/core/`) are pure functions — no I/O, no side effects, no dependencies on infrastructure.
- **Infra modules** (`src/infra/`) handle all I/O: Redis, filesystem, subprocess spawning, HTTP.
- **Orchestration modules** (`src/orchestration/`) wire core logic to infra adapters. They may have side effects but should delegate decisions to core.

## Immutability

- Prefer `readonly` arrays and objects in type signatures.
- Never mutate function arguments — always return new values.
- Use `as const` for literal objects where applicable.

## Parse, Don't Validate

- Validate at the boundary (infra layer), parse into strongly-typed domain objects.
- Once data enters the core, it's already guaranteed correct by its type.
- Use Zod schemas at ingress points; branded types for domain identifiers.

## Error Handling

- Use `Result<T, E>` (discriminated union `{ ok: true; value: T } | { ok: false; error: E }`) for expected failures.
- Reserve exceptions for truly exceptional (programmer error) scenarios.
- Never let infrastructure errors propagate silently — log and wrap.

## Testability

- All modules accept dependencies via injection (function parameters or factory arguments).
- No global singletons. No hidden state.
- Core logic is testable with zero mocks — just call the function with inputs and assert outputs.
- Integration tests use injected fakes for I/O adapters.

## Algebraic Data Types

- Use discriminated unions (`type X = { kind: 'a'; ... } | { kind: 'b'; ... }`) for domain concepts with variants.
- Exhaustive matching via `ts-pattern` — never use `default` in match expressions over domain types.
- Make illegal states unrepresentable in the type system.
