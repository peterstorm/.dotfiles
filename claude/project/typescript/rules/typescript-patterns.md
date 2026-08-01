# TypeScript Patterns

## Branded Types

- Use branded types for domain identifiers: `type SkillId = string & { readonly __brand: 'SkillId' }`.
- Always provide a smart constructor (`makeSkillId`) that validates and returns `Result<SkillId, string>`.
- Never cast raw strings to branded types outside the constructor.

## Discriminated Unions + ts-pattern

- Model domain events, commands, and states as discriminated unions.
- Use `ts-pattern`'s `match()` for exhaustive, type-safe branching.
- Prefer `.exhaustive()` over `.otherwise()` to catch missing cases at compile time.

## Result Pattern

```typescript
type Result<T, E = string> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: E };
```

- Use for all operations that can fail expectedly.
- Compose with `map`, `flatMap` helpers when chaining.
- At the boundary (imperative shell), unwrap and handle — never propagate `Result` into the UI layer.

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
