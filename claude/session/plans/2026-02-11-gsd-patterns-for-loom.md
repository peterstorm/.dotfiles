# Plan: GSD Patterns for Loom Orchestration

**Spec:** `.claude/specs/2026-02-11-gsd-patterns-for-loom/spec.md`
**Created:** 2026-02-11

## Summary

Enhance loom with 4 GSD-derived patterns: (1) enhanced brainstorm with parallel research agents + decision-locking, (2) plan validation checking requirement coverage and dependency correctness before execute, (3) deviation logging giving impl agents graduated autonomy with structured tracking, (4) archive-on-complete moving artifacts to `.claude/archive/`. All changes preserve existing hook architecture — new logic added as pure functions, template enhancements, and parser extensions.

---

## Architectural Decisions

### AD-1: Plan Validation as Pure Helper Function (not agent, not hook)

**Choice:** New `validate-plan.ts` helper with pure validation functions, called by orchestrator via CLI after decompose.
**Why:** Spec requires NFR-011 (not PreToolUse hook, not new PHASE_ORDER entry). Pure functions are trivially testable with fixture data. Orchestrator calls `bun cli.ts helper validate-plan` between decompose and execute — same pattern as `validate-task-graph`.
**Rejected:**
- Separate validation agent — wastes API call for deterministic check; agent can hallucinate false passes
- PreToolUse hook on Task tool — spec explicitly excludes this (NFR-011)

### AD-2: Deviation Extraction via New Parser Module (not regex on transcript text)

**Choice:** New `parse-deviations.ts` parser that scans structured JSONL transcript for deviation markers output by impl agent.
**Why:** Follows existing parser architecture (parse-transcript, parse-files-modified, parse-bash-test-output). Pure function, no I/O. Agents output structured `[DEVIATION Rule N: description]` markers — parser extracts them. Graceful fallback: empty array if no markers found (NFR-012 compatibility).
**Rejected:**
- Free-text regex on transcript plain text — fragile, high false-positive rate
- Separate deviation reporting tool call — requires hook system changes out of scope

### AD-3: Brainstorm Research Agents as Task Tool Spawns Within Brainstorm Agent

**Choice:** Brainstorm agent spawns 3 Task tool calls in single message (codebase explorer via Explore, external researcher via general-purpose with web search, risk analyst via general-purpose). No intermediate files — brainstorm agent reads Task return values and synthesizes in-context before writing brainstorm.md.
**Why:** Spec FR-001/NFR-020 requires brainstorm agent to spawn internally via Task tool with no separate research artifact files. Simplest orchestration — brainstorm agent owns entire research+synthesis flow. Nested agents (Task-in-Task) don't trigger loom hooks since they're utility agents inside a phase agent.
**Rejected:**
- Sequential research by brainstorm agent — defeats parallelism purpose (US2, SC-002)
- Separate research phase — spec says no new PHASE_ORDER entries
- File-based handoff (agents write .md files) — unnecessary indirection, hooks block utility agent writes during pre-execute

### AD-4: Decision-Locking as Template Section (not state field)

**Choice:** Add decision-locking section to brainstorm template output format. Downstream phases read brainstorm.md directly.
**Why:** Decisions are consumed by human-in-the-loop specify/architecture agents who read brainstorm.md. No hooks need to enforce decision consistency — agents read the artifact. Keeps state file minimal (only machine-actionable fields).
**Rejected:**
- New `locked_decisions` field in TaskGraph state — over-engineering; no hook needs this data
- Separate decisions.md file — spec resolved to keep in brainstorm.md output

### AD-5: Archive as Copy-Then-Verify-Then-Delete Pattern

**Choice:** Archive function copies files to `.claude/archive/{slug}/`, verifies copy completeness, then deletes originals. Pure path computation + imperative I/O at edges.
**Why:** Risk table identifies data loss as HIGH impact. Atomic copy-verify-delete prevents partial moves. Pure function computes source/dest paths; I/O wrapper executes.
**Rejected:**
- `git mv` — archive dir might not be tracked; also doesn't handle spec subdirectory structure
- Direct `fs.renameSync` — fails across filesystem boundaries; no verification step

---

## File Structure

### Plan Validation

```
.claude/hooks/loom/src/handlers/helpers/validate-plan.ts        -- plan validation logic (pure functions + handler)
.claude/hooks/loom/tests/handlers/validate-plan.test.ts         -- unit tests with fixture task graphs and specs
```

### Deviation Logging

```
.claude/hooks/loom/src/parsers/parse-deviations.ts              -- extract deviation markers from JSONL transcript
.claude/hooks/loom/tests/parsers/parse-deviations.test.ts       -- unit tests with transcript fixtures
.claude/hooks/loom/src/types.ts                                 -- add Deviation type + deviations field to Task
.claude/hooks/loom/src/handlers/subagent-stop/update-task-status.ts -- extract and store deviations on task completion
.claude/skills/loom/templates/impl-agent-context.md             -- add 4-rule deviation framework
```

### Brainstorm Enhancement

```
.claude/skills/loom/templates/phase-brainstorm.md               -- add research agent spawning + decision-locking
```

### Archive on Complete

```
.claude/hooks/loom/src/handlers/helpers/archive-complete.ts     -- archive logic (pure path computation + I/O)
.claude/hooks/loom/tests/handlers/archive-complete.test.ts      -- unit tests
.claude/skills/loom/SKILL.md                                    -- update --complete docs
.claude/hooks/loom/src/cli.ts                                   -- register archive-complete handler
.claude/hooks/loom/src/config.ts                                -- add archive-complete to WHITELISTED_HELPERS
```

### CLI Registration

```
.claude/hooks/loom/src/cli.ts                                   -- register validate-plan handler
```

---

## Component Design

### PlanValidator (pure)

**Responsibility:** Validate decompose output against spec for requirement coverage, dependency cycles, file ownership overlap, and task description specificity.
**Files:** `.claude/hooks/loom/src/handlers/helpers/validate-plan.ts`, `.claude/hooks/loom/tests/handlers/validate-plan.test.ts`
**Interface:**

```typescript
// Severity levels for findings
type FindingSeverity = "blocker" | "warning" | "info";

interface PlanFinding {
  severity: FindingSeverity;
  code: string;       // e.g. "UNCOVERED_ANCHOR", "DEPENDENCY_CYCLE", "FILE_OVERLAP", "VAGUE_TASK"
  message: string;
  details?: string[];
}

interface PlanValidationResult {
  verdict: "PASSED" | "BLOCKED" | "WARNINGS";
  findings: PlanFinding[];
}

// Pure functions — no I/O, no state reads
function checkAnchorCoverage(tasks: Task[], specAnchors: string[]): PlanFinding[];
function checkDependencyCycles(tasks: Task[]): PlanFinding[];
function checkFileOwnershipOverlap(tasks: Task[]): PlanFinding[];
function checkTaskSpecificity(tasks: Task[]): PlanFinding[];
function validatePlan(tasks: Task[], specAnchors: string[]): PlanValidationResult;

// Impure: reads spec file to extract anchors (I/O at edge)
function extractSpecAnchors(specContent: string): string[];
```

**Depends on:** types.ts (Task type)

### DeviationParser (pure)

**Responsibility:** Extract structured deviation entries from impl agent JSONL transcript.
**Files:** `.claude/hooks/loom/src/parsers/parse-deviations.ts`, `.claude/hooks/loom/tests/parsers/parse-deviations.test.ts`
**Interface:**

```typescript
// New type in types.ts
interface Deviation {
  rule: 1 | 2 | 3 | 4;
  description: string;
  outcome: string;
}

// Pure: operates on transcript content string
function parseDeviations(transcriptContent: string): Deviation[];
```

**Depends on:** parsers/types.ts (parseJsonl, getContentBlocks)

### ImplAgentDeviationRules (template)

**Responsibility:** Provide 4-rule deviation framework as prompt-only guidance in impl agent context template.
**Files:** `.claude/skills/loom/templates/impl-agent-context.md`
**Interface:** N/A (template text — consumed by brainstorm/execute orchestrator)
**Depends on:** none

### BrainstormEnhancement (template)

**Responsibility:** Add parallel research agent spawning instructions and decision-locking output format to brainstorm template.
**Files:** `.claude/skills/loom/templates/phase-brainstorm.md`
**Interface:** N/A (template text — consumed by loom orchestrator when spawning brainstorm-agent)
**Depends on:** none

### ArchiveComplete (pure core + I/O shell)

**Responsibility:** Move spec directory and plan file to `.claude/archive/{slug}/` on workflow completion.
**Files:** `.claude/hooks/loom/src/handlers/helpers/archive-complete.ts`, `.claude/hooks/loom/tests/handlers/archive-complete.test.ts`
**Interface:**

```typescript
// Pure: compute archive paths from state
interface ArchivePaths {
  specSource: string;        // .claude/specs/{slug}/
  specDest: string;          // .claude/archive/{slug}/spec/
  planSource: string;        // .claude/plans/{slug}.md
  planDest: string;          // .claude/archive/{slug}/plan.md
}
function computeArchivePaths(specDir: string, planFile: string): ArchivePaths;

// Pure: verify all expected files exist at destination
function verifyArchive(paths: ArchivePaths, fileExists: (p: string) => boolean): string[];

// Handler (I/O): copy, verify, delete originals, remove state file
// Usage: bun cli.ts helper archive-complete
```

**Depends on:** types.ts (TaskGraph), state-manager.ts (StateManager)

### UpdateTaskStatusEnhancement (modify existing)

**Responsibility:** Extend update-task-status handler to extract deviations from transcript and store in task state.
**Files:** `.claude/hooks/loom/src/handlers/subagent-stop/update-task-status.ts`
**Interface:** Existing handler — adds `deviations` field to task state update.
**Depends on:** DeviationParser

### TaskTypeExtension (modify existing)

**Responsibility:** Add `Deviation` type and `deviations` field to Task interface.
**Files:** `.claude/hooks/loom/src/types.ts`
**Interface:**

```typescript
// Added to types.ts
interface Deviation {
  rule: 1 | 2 | 3 | 4;
  description: string;
  outcome: string;
}

// Extended Task interface
interface Task {
  // ... existing fields ...
  deviations?: Deviation[];
}
```

**Depends on:** none

---

## Data Flow

### Plan Validation Flow

```
decompose-agent output (JSON) --> extractSpecAnchors(spec.md) --> validatePlan(tasks, anchors)
  --> PlanValidationResult { verdict, findings[] }
    --> if BLOCKED: re-spawn decompose with error details
    --> if PASSED/WARNINGS: proceed to populate-task-graph
```

Orchestrator reads spec file content and task graph JSON, passes both as data to pure validation functions. No state file reads required.

### Deviation Logging Flow

```
impl-agent transcript (JSONL) --> parseDeviations(content) --> Deviation[]
  --> update-task-status handler stores in task.deviations[]
```

Same data path as existing parseFilesModified and parseBashTestOutput — added as parallel extraction step in update-task-status handler.

### Brainstorm Research Flow

```
/loom "feature" --> brainstorm-agent spawns 3 Task calls (single message):
  Task(Explore, "scan codebase for patterns...") --> returns findings as text
  Task(general-purpose, "web search for best practices...") --> returns findings as text
  Task(general-purpose, "identify risks and pitfalls...") --> returns findings as text
--> brainstorm-agent reads all 3 return values in-context
--> synthesizes into approach options + runs decision-locking step
--> writes brainstorm.md with Decisions section (locked/discretion/deferred)
```

All orchestration happens within brainstorm-agent via its enhanced template. No intermediate files, no hooks involved. Nested Task-in-Task agents don't trigger loom hooks.

### Archive Flow

```
/loom --complete --> orchestrator calls: bun cli.ts helper archive-complete
  --> computeArchivePaths(state.spec_dir, state.plan_file)
  --> copy spec dir to archive
  --> copy plan file to archive
  --> verifyArchive(paths) -- check all files present
  --> delete originals
  --> remove state file
```

---

## Implementation Phases

### Phase 1: Type Extensions + Pure Validators (no dependencies)

- Add `Deviation` interface and `deviations?: Deviation[]` to Task in types.ts
- Implement `parse-deviations.ts` parser with unit tests
- Implement `validate-plan.ts` with all pure validation functions and unit tests
- Implement `archive-complete.ts` with pure path computation and archive handler with unit tests
- Register `validate-plan` and `archive-complete` in cli.ts KNOWN_HANDLERS
- Add `archive-complete` to WHITELISTED_HELPERS in config.ts
- **Files:** `types.ts`, `parse-deviations.ts`, `parse-deviations.test.ts`, `validate-plan.ts`, `validate-plan.test.ts`, `archive-complete.ts`, `archive-complete.test.ts`, `cli.ts`, `config.ts`

### Phase 2: Template Enhancements (no dependencies)

- Enhance `phase-brainstorm.md` with parallel research agent spawning instructions and decision-locking output format
- Enhance `impl-agent-context.md` with 4-rule deviation framework (rules, examples, logging format)
- Update `SKILL.md` with `--complete` documentation referencing archive-complete handler
- **Files:** `phase-brainstorm.md`, `impl-agent-context.md`, `SKILL.md`

### Phase 3: Integration (depends on Phase 1)

- Modify `update-task-status.ts` to call `parseDeviations()` and store results in task state
- Update `SKILL.md` Phase 4 section to document plan validation step between decompose output validation and user approval
- **Files:** `update-task-status.ts`, `SKILL.md`

---

## Testing Strategy

| Component | Unit Tests | Integration Tests | Property Tests |
|-----------|-----------|-------------------|----------------|
| PlanValidator | checkAnchorCoverage with covered/uncovered specs; checkDependencyCycles with acyclic/cyclic graphs; checkFileOwnershipOverlap with overlapping/non-overlapping file lists; checkTaskSpecificity with vague/specific descriptions | None (pure functions only) | Invariant: valid graph with all anchors mapped always returns PASSED; adding uncovered anchor always returns BLOCKED |
| DeviationParser | Transcript with 0/1/multiple deviations; mixed rule numbers; malformed markers (graceful skip); empty transcript | None (pure function) | Invariant: parseDeviations on transcript without `[DEVIATION` markers always returns `[]` |
| ArchiveComplete | computeArchivePaths with various slug formats; verifyArchive with complete/incomplete copies | Handler test with temp directory (fs operations) | None |
| UpdateTaskStatus (deviation integration) | Existing tests + new test: transcript with deviations stores them in task state | None (existing test covers handler flow) | None |
| BrainstormTemplate | N/A (prompt template) | Manual: run brainstorm, verify 3 agents spawned and decisions section present | None |
| ImplAgentTemplate | N/A (prompt template) | Manual: run impl agent with deviation scenario, verify markers in transcript | None |

### Key Test Fixtures

**Plan Validation:**
- Spec with FR-001 through FR-005: task graph mapping all vs missing FR-003
- Task graph with cycle: T1->T2->T3->T1
- Wave 1 tasks with overlapping file_list entries
- Task with description "do stuff" (vague) vs "Create POST handler in src/api/auth.ts" (specific)

**Deviation Parsing:**
- JSONL transcript with `[DEVIATION Rule 1: Fixed missing import for UserService]` in assistant text block
- Transcript with multiple deviations across different rules
- Transcript with no deviation markers (empty result)
- Transcript with malformed `[DEVIATION ...]` (graceful skip)

---

## Security & NFR Notes

- **Performance:** Plan validation is pure computation on small data (NFR-002: <5s for 12 tasks). No external calls.
- **Compatibility:** All changes preserve existing hook architecture (NFR-010). No new PHASE_ORDER entries (NFR-011). Deviation logging reuses SubagentStop handler pattern (NFR-012).
- **Data Safety:** Archive uses copy-verify-delete pattern. Rollback on verification failure prevents data loss.

---

## Verification

1. `cd .claude/hooks/loom && bun test` -- all existing + new tests pass
2. `bun cli.ts helper validate-plan < fixture.json` -- returns PASSED/BLOCKED correctly
3. `bun cli.ts helper archive-complete` -- moves files, verifies, cleans state
4. Manual: run `/loom` on test feature, verify brainstorm spawns 3 research agents, produces decision-locking section
5. Manual: run impl agent with intentional deviation, verify `[DEVIATION Rule N: ...]` extracted and stored in task state

---

## Unresolved Questions

- Spec anchor extraction regex: exact patterns to match FR-xxx, SC-xxx, US.acceptance in spec markdown? Plan assumes `/(?:FR|SC|NFR|US\d+\.acceptance)-\d+/g` but spec might use other formats.
- Decision-locking skip heuristic: what constitutes "simple feature with no detected ambiguity" (FR-004)? Template says brainstorm agent decides — no automated detection.
- Research agent model: resolved — codebase explorer = Explore agent, external researcher + risk analyst = general-purpose.
