---
name: code-implementer
description: "This skill should be used when the user asks to 'implement', 'write code', 'build a feature', 'create a function', 'add functionality', 'code this', 'make this work', or needs to write production code for Java/Spring Boot or TypeScript/Next.js following FP, DDD, and testability patterns. Ensures code follows functional core/imperative shell, proper invariants, Either-based error handling, and is designed for testing without mocks."
---

# Code Implementer Skill

Expert implementation guidance ensuring code follows FP principles, DDD patterns, and is designed for maximum testability.

**This is an IMPLEMENTATION skill** - write production code following the architectural patterns. For design decisions and architectural review, use `/architecture-tech-lead` instead.

## Context Loading

Before implementing, load the relevant rules. Read ONLY what's needed:

**Always read:**
- `~/.dotfiles/claude/project/meta/rules/architecture.md` - core principles (FC/IS, DDD, immutability)

**Java** (if implementing Java/Spring Boot):
- `~/.dotfiles/claude/project/java/rules/java-patterns.md` - records, sealed types, Either, railway-oriented programming
- `~/.dotfiles/claude/project/java/rules/property-testing.md` - jqwik invariants

**TypeScript** (if implementing TypeScript/Next.js):
- `~/.dotfiles/claude/project/typescript/rules/typescript-patterns.md` - discriminated unions, branded types, ts-pattern

**Rust** (if implementing Rust):
- `~/.dotfiles/claude/project/rust/rules/rust-patterns.md` - newtype, typestate, Result combinators

---

## Pre-Implementation Checklist

Before writing code, verify:

- [ ] **Boundaries clear**: Where does I/O happen vs pure logic?
- [ ] **Invariants identified**: What must always be true?
- [ ] **Types designed**: Records/sealed types for domain? Discriminated unions?
- [ ] **Parse, don't validate**: Return validated types? Invalid states unrepresentable?
- [ ] **Error handling**: Using Either/Result? What errors are possible?
- [ ] **Testability**: Can business logic be unit tested without mocks?

---

## During Implementation

### Structure Code as Functional Core + Imperative Shell

**Imperative Shell (thin)**:
- Fetches data (DB, APIs)
- Calls pure functions
- Persists results
- Handles I/O errors

**Functional Core (where logic lives)**:
- Pure functions, no side effects
- Receives all data as parameters
- Returns new data, never mutates
- Trivially unit testable

### Apply Type Design

Apply patterns from loaded rules:
- **Java**: Records, sealed types, pattern matching (see java-patterns.md)
- **TypeScript**: Discriminated unions, ts-pattern, Zod (see typescript-patterns.md)
- **Rust**: Newtypes, enums, typestate (see rust-patterns.md)

### Handle Errors Properly

Use Either/Result for all expected failures:
- Chain operations with `flatMap`
- Collect validation errors with `Eithers.allFailures()`
- Never throw for expected failures - return typed errors

---

## Post-Implementation Checklist

After writing code, verify:

- [ ] **No business logic in shell**: All logic in pure functions?
- [ ] **Immutability**: No mutations? Defensive copies where needed?
- [ ] **Invariants enforced**: Constructors validate? Invalid states unrepresentable?
- [ ] **Error paths typed**: Using Either/Result? No hidden throws?
- [ ] **Testable without mocks**: Can test core logic with plain data?

---

## Implementation Patterns Quick Reference

### Data Transformation Flow
```
fetch (I/O) -> transform (pure) -> persist (I/O)
```

### Service Method Structure
```
1. Fetch required data (shell - I/O)
2. Call pure function with data (core - testable)
3. Persist result (shell - I/O)
4. Return result
```

### Invariant Enforcement
```
Constructor validates -> Object always valid -> No defensive checks elsewhere
```

### Error Handling Chain
```
validate -> process -> transform -> (all via flatMap/map)
```

---

## Test Strategy

For every implementation, consider:

### Unit Tests (core logic)
- Test pure functions with plain data
- No mocks needed
- Cover edge cases

### Property Tests (invariants)
- What must ALWAYS be true?
- Round-trip properties
- Idempotence where applicable

### Integration Tests (shell only)
- Minimal - just verify I/O works
- Use real DB/APIs in test containers
- Don't test business logic here

---

## Quality Standards

- **Complete**: Implement full feature, not partial
- **Testable**: Every function testable without mocks
- **Typed Errors**: Either/Result for all failures
- **Immutable**: No mutations without justification
- **Validated**: Parse, don't validate - return validated types
