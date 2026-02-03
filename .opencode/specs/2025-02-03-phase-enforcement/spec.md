# Phase Enforcement for OpenCode Task-Planner Plugin

**Version:** 1.0  
**Date:** 2025-02-03  
**Status:** Complete (all clarifications resolved)  
**Author:** Specify Agent  

---

## 1. Overview

### 1.1 What This Phase Implements

Phase 2 of the OpenCode task-planner plugin conversion implements **phase order validation and advancement** to enforce the structured workflow:

```
init → brainstorm → specify → clarify → architecture → decompose → execute
```

This includes:
1. **validate-phase-order hook** - Blocks Skill invocations that violate phase ordering
2. **advance-phase hook** - Automatically advances the current phase when completion markers are detected

### 1.2 Why It's Needed

Without phase enforcement, users could:
- Invoke implementation agents before requirements are specified
- Skip critical phases like architecture, leading to unplanned code
- Lose traceability between specification artifacts and implementation

The Claude Code implementation used `PreToolUse` and `SubagentStop` hooks. OpenCode lacks `SubagentStop`, requiring an alternative approach using `session.idle` and `message.updated` events to detect phase completion.

### 1.3 Scope

This specification covers:
- Phase transition validation logic
- Phase completion detection mechanisms
- Skip flag handling
- Artifact requirement validation

---

## 2. Functional Requirements

### FR-001: Block Skill Invocations for Invalid Phase Transitions

**Priority:** MUST

**Description:** The system MUST block `skill` tool invocations when the requested skill would transition to a phase that violates the expected phase order.

**Valid transitions:**
| From Phase    | To Phase(s)                    |
|---------------|--------------------------------|
| `init`        | `brainstorm`, `specify`        |
| `brainstorm`  | `specify`                      |
| `specify`     | `clarify`, `architecture`      |
| `clarify`     | `architecture`                 |
| `architecture`| `decompose`                    |
| `decompose`   | `execute`                      |
| `execute`     | `execute` (multiple tasks OK)  |

**Acceptance:** 
- Invoking `architecture-tech-lead` skill from `init` phase throws a blocking error
- Error message includes current phase, attempted phase, and valid next steps

---

### FR-002: Map Skills to Phases

**Priority:** MUST

**Description:** The system MUST map OpenCode skill names to their corresponding workflow phases.

**Skill-to-Phase mapping:**

| Skill Name             | Phase          |
|------------------------|----------------|
| `brainstorming`        | `brainstorm`   |
| `specify`              | `specify`      |
| `clarify`              | `clarify`      |
| `architecture-tech-lead` | `architecture` |
| `task-planner`         | `decompose`    |
| `code-implementer`     | `execute`      |
| `java-test-engineer`   | `execute`      |
| `ts-test-engineer`     | `execute`      |
| `nextjs-frontend-design` | `execute`    |
| `security-expert`      | `execute`      |
| `k8s-expert`           | `execute`      |
| `keycloak-expert`      | `execute`      |
| `dotfiles-expert`      | `execute`      |
| `spec-check`           | `execute`      |
| `review-skill`         | `execute`      |
| `wave-gate`            | `execute`      |

**Acceptance:**
- All listed skills are correctly mapped
- Unknown skills are allowed to pass (no blocking) when no task graph is active

---

### FR-003: Handle Skipped Phases

**Priority:** MUST

**Description:** The system MUST respect the `skipped_phases` array in the TaskGraph when validating phase transitions.

**Skip rules:**
- `brainstorm` MAY be skipped (direct `init` → `specify`)
- `clarify` MAY be skipped when `[NEEDS CLARIFICATION]` markers ≤ 3
- Other phases (`specify`, `architecture`, `decompose`, `execute`) MUST NOT be skipped

**Acceptance:**
- If `brainstorm` is in `skipped_phases`, `init` → `specify` is valid
- If `clarify` is in `skipped_phases`, `specify` → `architecture` is valid
- Attempting to skip `architecture` throws a blocking error

---

### FR-004: Validate Artifact Prerequisites

**Priority:** MUST

**Description:** The system MUST verify that prerequisite phase artifacts exist before allowing a phase transition.

**Artifact requirements:**

| Target Phase   | Required Artifact                          |
|----------------|-------------------------------------------|
| `clarify`      | `phase_artifacts.specify` file exists     |
| `architecture` | `phase_artifacts.specify` file exists AND (markers ≤ 3 OR clarify completed/skipped) |
| `decompose`    | `phase_artifacts.architecture` file exists |
| `execute`      | `phase_artifacts.architecture` file exists AND tasks defined |

**Acceptance:**
- Invoking `architecture-tech-lead` without a spec file throws error with message "spec.md not found"
- Error message identifies the missing prerequisite

---

### FR-005: Advance Phase on Completion Detection

**Priority:** MUST

**Description:** The system MUST automatically advance `current_phase` when phase completion is detected through message content markers.

**Completion markers (regex patterns):**

| Phase          | Completion Pattern                                                |
|----------------|------------------------------------------------------------------|
| `brainstorm`   | `/(?:brainstorm(?:ing)?|exploration)\s+(?:complete|done|finished)/i` |
| `specify`      | `/spec(?:ification)?\s+(?:complete|written|created|saved)/i`     |
| `clarify`      | `/clarif(?:y|ication)\s+(?:complete|resolved|done)/i`            |
| `architecture` | `/(?:architecture|design|plan)\s+(?:complete|done|created)/i`   |
| `decompose`    | `/(?:decompos(?:e|ition)|tasks?)\s+(?:complete|created|defined)/i` |

**Acceptance:**
- When `message.updated` fires with content matching `specify` completion pattern, `current_phase` advances to next phase
- Phase advancement respects skip rules (e.g., auto-skip clarify if markers ≤ 3)

---

### FR-006: Record Phase Artifacts on Advancement

**Priority:** MUST

**Description:** The system MUST record the artifact file path in `phase_artifacts` when a phase completes.

**Artifact detection:**
- Extract file paths from message content using pattern: `/(?:saved|created|wrote|generated).*?([^\s]+\.md)/i`
- Store in `phase_artifacts[completedPhase]`

**Acceptance:**
- After specify phase completes with "Spec saved to .opencode/specs/.../spec.md", `phase_artifacts.specify` contains that path
- If no file path detected, set artifact to `"completed"`

---

### FR-007: Auto-Skip Clarify Phase Based on Markers

**Priority:** MUST

**Description:** The system MUST automatically skip the `clarify` phase and add it to `skipped_phases` when the specification file contains 3 or fewer `[NEEDS CLARIFICATION]` markers.

**Logic:**
1. When `specify` phase completes, read the spec file
2. Count occurrences of `[NEEDS CLARIFICATION]` pattern
3. If count ≤ 3: add `clarify` to `skipped_phases` and advance to `architecture`
4. If count > 3: advance to `clarify`

**Acceptance:**
- Spec with 2 markers auto-skips to `architecture`
- Spec with 5 markers requires `clarify` phase
- Console output indicates "clarify auto-skipped: markers ≤ 3"

---

### FR-008: Block Unknown Skills During Active Orchestration

**Priority:** SHOULD

**Description:** The system SHOULD block invocation of unrecognized skills when an active task graph exists and `current_phase` is not `execute`.

**Rationale:** Prevents bypass of phase enforcement via unmapped skills.

**Exceptions:**
- Skills invoked during `execute` phase are allowed (implementation flexibility)
- Skills invoked when no task graph exists are allowed

**Acceptance:**
- Unknown skill during `specify` phase is blocked
- Unknown skill during `execute` phase is allowed
- Error message lists recognized phase skills

**Note:** Utility skills in `PHASE_EXEMPT_SKILLS` are allowed regardless of phase (see Q1 resolution).

---

### FR-009: Provide Actionable Error Messages

**Priority:** MUST

**Description:** The system MUST provide error messages that clearly explain:
1. What was blocked
2. Why it was blocked (current phase, missing prerequisite)
3. What action to take next

**Error message template:**
```
BLOCKED: [Reason]

Current phase: [current_phase]
Attempted: [skill_name] → [target_phase]

[Specific guidance for resolution]
```

**Acceptance:**
- All blocking errors include current phase
- All blocking errors include suggested next step
- Messages use existing `ERRORS` constants from `constants.ts`

---

### FR-010: Handle Missing Task Graph Gracefully

**Priority:** MUST

**Description:** The system MUST allow all skill invocations when no active task graph exists (file not found or empty).

**Acceptance:**
- Skill invocations pass without blocking when `.opencode/state/active_task_graph.json` does not exist
- No errors thrown for missing state file

---

## 3. User Stories

### US-1: Developer Following Structured Workflow

**As a** developer using task-planner orchestration  
**I want** phase enforcement to prevent me from skipping steps  
**So that** I maintain a complete audit trail from requirements to implementation

**Scenario:**
1. Developer initializes a feature with `/plan Feature X`
2. Attempts to invoke `code-implementer` skill directly
3. System blocks with message: "BLOCKED: Cannot execute during init phase. Run brainstorming or specify first."
4. Developer runs brainstorming skill, then specify skill
5. System allows progression through phases in order

---

### US-2: Developer Skipping Optional Brainstorm

**As a** developer with a clear feature idea  
**I want** to skip brainstorming and start with specification  
**So that** I don't waste time on unnecessary exploration

**Scenario:**
1. Developer invokes specify skill from init phase
2. System allows transition (brainstorm is skippable)
3. System adds `brainstorm` to `skipped_phases`
4. Workflow continues from specify phase

---

### US-3: Developer with Complex Spec Needing Clarification

**As a** developer with an ambiguous specification  
**I want** the system to require clarification when there are many open questions  
**So that** I don't proceed to architecture with unresolved requirements

**Scenario:**
1. Specify phase completes with 5 `[NEEDS CLARIFICATION]` markers
2. System advances to `clarify` phase (not architecture)
3. Developer must run clarify skill to resolve markers
4. After clarification, system allows architecture phase

---

### US-4: Developer with Clean Spec Auto-Skipping Clarify

**As a** developer with a well-defined specification  
**I want** clarify phase to be automatically skipped  
**So that** I can proceed directly to architecture without manual intervention

**Scenario:**
1. Specify phase completes with 1 `[NEEDS CLARIFICATION]` marker
2. System detects markers ≤ 3
3. System adds `clarify` to `skipped_phases`
4. System advances directly to `architecture` phase
5. Console shows "clarify auto-skipped: markers ≤ 3"

---

## 4. Technical Requirements

### TR-001: Hook Implementation Files

**Priority:** MUST

**Description:** Phase 2 MUST implement two new hook files:

| File                                  | Purpose                              |
|---------------------------------------|--------------------------------------|
| `hooks/validate-phase-order.ts`       | Pre-skill validation (tool.execute.before) |
| `hooks/advance-phase.ts`              | Phase advancement (message.updated + session.idle) |

Both files MUST:
- Export a function compatible with the plugin event handler signature
- Use the existing `StateManager` for state operations
- Use existing types from `types.ts`

---

### TR-002: Constants for Skill-to-Phase Mapping

**Priority:** MUST

**Description:** The system MUST define skill-to-phase mappings in `constants.ts`.

**Required additions:**
```typescript
export const SKILL_TO_PHASE: Record<string, Phase> = {
  "brainstorming": "brainstorm",
  "specify": "specify",
  // ... full mapping
};

export const PHASE_COMPLETION_PATTERNS: Record<Phase, RegExp> = {
  "brainstorm": /(?:brainstorm(?:ing)?|exploration)\s+(?:complete|done|finished)/i,
  // ... patterns for each phase
};
```

---

### TR-003: State Manager Extensions

**Priority:** SHOULD

**Description:** The StateManager SHOULD be extended with convenience methods for phase enforcement:

| Method                        | Purpose                                    |
|-------------------------------|--------------------------------------------|
| `getSkippedPhases()`          | Return `skipped_phases` array              |
| `addSkippedPhase(phase)`      | Add phase to `skipped_phases`              |
| `advancePhase(nextPhase)`     | Atomically update `current_phase`          |
| `getArtifact(phase)`          | Return `phase_artifacts[phase]`            |
| `checkArtifactExists(phase)`  | Verify artifact file exists on disk        |

**Note:** Some methods already exist (`setCurrentPhase`, `setPhaseArtifact`). Only add missing ones.

---

### TR-004: Plugin Index Integration

**Priority:** MUST

**Description:** The main `index.ts` MUST be updated to integrate the new hooks:

1. Import `validatePhaseOrder` from `hooks/validate-phase-order.ts`
2. Import `advancePhase` from `hooks/advance-phase.ts`
3. Call `validatePhaseOrder` in `tool.execute.before` handler
4. Call `advancePhase` in `message.updated` handler

---

### TR-005: Session Idle Handling for Phase Advancement

**Priority:** SHOULD

**Description:** The system SHOULD use `session.idle` as a secondary trigger for phase advancement.

**Rationale:** If `message.updated` fails to detect completion (e.g., non-standard wording), `session.idle` provides a fallback.

**Logic:**
1. On `session.idle`, check if the last message indicates phase completion
2. If completion detected, trigger phase advancement

**Note:** Per Q2 resolution, always check when task graph exists, with debouncing.

---

### TR-006: Concurrent Access Safety

**Priority:** MUST

**Description:** All phase operations MUST use the existing file locking mechanism in StateManager to prevent race conditions.

**Specific scenarios:**
- Two skill invocations checking phase order simultaneously
- Phase advancement during another phase validation

**Acceptance:**
- All state reads/writes use `withLock()` pattern
- Lock timeout follows existing `LOCK_TIMEOUT_MS` constant

---

## 5. Security Considerations

### SC-001: State File Integrity

**Priority:** MUST

**Description:** The system MUST NOT allow external modification of phase state via Bash or other tools that bypass the plugin.

**Implementation:** Already covered by `guard-state-file.ts` from Phase 1.

---

### SC-002: Skill Name Injection Prevention

**Priority:** MUST

**Description:** The system MUST validate skill names against the allowlist rather than using pattern matching that could be bypassed.

**Acceptance:**
- Skill names are matched exactly against `SKILL_TO_PHASE` keys
- Partial matches or pattern-based matching are not used
- Unknown skills are handled per FR-008

---

### SC-003: Artifact Path Validation

**Priority:** SHOULD

**Description:** The system SHOULD validate that artifact paths are within expected directories to prevent path traversal.

**Allowed paths:**
- `.opencode/specs/**/*.md`
- `.opencode/plans/**/*.md`
- `.claude/specs/**/*.md` (legacy, with deprecation warning)
- `.claude/plans/**/*.md` (legacy, with deprecation warning)

**Acceptance:**
- Artifact paths outside allowed directories are rejected
- Error message indicates "Invalid artifact path"
- Legacy `.claude/` paths emit console warning

---

## 6. Acceptance Criteria

### AC-1: Phase Validation Works End-to-End

- [ ] Skill invocation from `init` to `code-implementer` is blocked
- [ ] Skill invocation from `init` to `brainstorming` is allowed
- [ ] Skill invocation from `init` to `specify` is allowed (brainstorm skippable)
- [ ] Skill invocation from `specify` to `architecture-tech-lead` is allowed (if spec exists)
- [ ] Error messages include current phase and next steps

### AC-2: Phase Advancement Works

- [ ] Completing brainstorm phase advances to `specify`
- [ ] Completing specify phase advances to `clarify` or `architecture` based on marker count
- [ ] Completing clarify phase advances to `architecture`
- [ ] Completing architecture phase advances to `decompose`
- [ ] Phase artifacts are recorded in state

### AC-3: Skip Flags Work

- [ ] `brainstorm` can be skipped via direct `specify` invocation
- [ ] `clarify` is auto-skipped when markers ≤ 3
- [ ] Skipped phases are recorded in `skipped_phases` array
- [ ] Non-skippable phases cannot be bypassed

### AC-4: Edge Cases Handled

- [ ] Missing task graph allows all skills
- [ ] Malformed task graph is handled gracefully (no crash)
- [ ] Concurrent access is serialized via locks
- [ ] Missing artifact files produce clear error messages

### AC-5: Tests Pass

- [ ] Unit tests for `validatePhaseOrder` function
- [ ] Unit tests for `advancePhase` function
- [ ] Integration tests with mocked StateManager
- [ ] All existing Phase 1 tests continue to pass

---

## 7. Out of Scope

The following are **NOT** included in Phase 2:

1. **Task-level enforcement** - Validating task dependencies and wave ordering (Phase 3)
2. **Review findings capture** - Parsing CRITICAL/ADVISORY markers (Phase 4)
3. **Spec-check integration** - Running spec-check agent automatically (Phase 4)
4. **GitHub issue creation** - Creating tracking issues (Phase 5)
5. **Agent context tracking** - Registering/unregistering agents (Phase 3)
6. **File modification tracking** - Associating file changes with tasks (Phase 3)
7. **Manual phase override** - Admin ability to force phase transitions
8. **Phase rollback** - Ability to go back to a previous phase

---

## 8. Open Questions

### Q1: Utility Skill Allowlist ✅ RESOLVED

Should certain skills be allowed regardless of phase? Candidates:
- `find-skills` - Meta skill for discovery
- `writing-clearly-and-concisely` - Pure utility
- `marketing-*` - Unrelated to dev workflow

**Resolution:** Create a `PHASE_EXEMPT_SKILLS` constant with these utility skills.

---

### Q2: Session Idle Trigger Conditions ✅ RESOLVED

When should `session.idle` trigger phase advancement checks?

Options:
1. Always when task graph exists ← **SELECTED**
2. Only when an agent is registered in `activeAgents`
3. Only when `current_phase` is not `init` or `execute`

**Resolution:** Option 1 - always check when task graph exists, with debouncing to prevent rapid re-checks.

---

### Q3: Legacy Path Support ✅ RESOLVED

Should Phase 2 support artifact paths in `.claude/` directory for migration compatibility?

**Resolution:** Yes, include `.claude/` in allowed paths but log deprecation warning.

---

### Q4: Marker Count Threshold

The current threshold for auto-skipping clarify is "≤ 3 markers." Is this appropriate, or should it be configurable?

**Note:** This is inherited from the Claude Code implementation and not a clarification need - just documenting the design decision.

---

## Appendix A: Existing Types Reference

From `types.ts`:
- `Phase`: `"init" | "brainstorm" | "specify" | "clarify" | "architecture" | "decompose" | "execute"`
- `TaskGraph.current_phase`: Current workflow phase
- `TaskGraph.phase_artifacts`: `Partial<Record<Phase, string | null>>`
- `TaskGraph.skipped_phases`: `Phase[]`

From `constants.ts`:
- `PHASE_ORDER`: Ordered array of phases
- `SKIPPABLE_PHASES`: `["brainstorm", "clarify"]`
- `ARTIFACT_PHASES`: Phases that produce artifacts
- `ERRORS.PHASE_ORDER_VIOLATION`: Error message template

---

## Appendix B: Claude Code Reference

The original implementations are in:
- `~/.claude/hooks/PreToolUse/validate-phase-order.sh`
- `~/.claude/hooks/SubagentStop/advance-phase.sh`

Key differences in OpenCode:
1. No `SubagentStop` event - use `session.idle` + `message.updated`
2. No `agent_type` metadata - infer from skill names
3. TypeScript instead of Bash - more robust parsing
