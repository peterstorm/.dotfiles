# TypeScript Patterns

## Branded Types

- Use branded types for domain identifiers: `type UserId = string & { readonly __brand: 'UserId' }`.
- Always provide a smart constructor (`makeUserId`) that validates and returns `Either<string, UserId>`.
- Never cast raw strings to branded types outside the constructor.

## Discriminated Unions + ts-pattern

- Model domain events, commands, and states as discriminated unions.
- Use `ts-pattern`'s `match()` for exhaustive, type-safe branching.
- Prefer `.exhaustive()` over `.otherwise()` to catch missing cases at compile time.

## Either Pattern

```typescript
type Either<E, A> =
  | { readonly _tag: 'Left'; readonly left: E }   // failure
  | { readonly _tag: 'Right'; readonly right: A } // success
```

- Use for all operations that can fail expectedly (use a library implementation — e.g. `effect` / `fp-ts` — when one is already in the project; hand-roll only in dependency-free code).
- Compose with `map`, `flatMap` helpers when chaining.
- At the boundary (imperative shell), unwrap and handle — never propagate `Either` into the UI layer.

## Readonly by Default

- All function parameters should use `readonly` variants.
- Arrays: `readonly T[]` or `ReadonlyArray<T>`.
- Objects: `Readonly<T>` or explicit `readonly` on each field.
- Records: `Readonly<Record<K, V>>`.

## Pure Functions First

- Extract logic into pure functions that take inputs and return outputs.
- Side effects belong in the infra layer.
- A function that reads its inputs and returns a deterministic output is always preferred over one that mutates or performs I/O.

## No `any`

- Never use `any`. Use `unknown` and narrow with type guards.
- For external API responses, define a Zod schema and parse at the boundary.
- For truly untyped interop, use a thin adapter with explicit casts documented by comments.

## Naming

- Types: `PascalCase`.
- Functions/variables: `camelCase`.
- Constants: `SCREAMING_SNAKE_CASE` only for true compile-time constants.
- Files: `kebab-case.ts`.
- Test files: `<module>.test.ts` co-located with source.
