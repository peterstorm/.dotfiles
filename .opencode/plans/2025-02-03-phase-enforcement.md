# Architecture Plan: Phase Enforcement for OpenCode Task-Planner Plugin

**Created:** 2025-02-03  
**Status:** Architecture  
**Spec:** `.opencode/specs/2025-02-03-phase-enforcement/spec.md`  
**Phase:** 2 of 5 (per claude-hooks-to-opencode-plugins.md)

---

## 1. Architecture Overview

### 1.1 High-Level Design

```
                        ┌─────────────────────────────────────────────┐
                        │           OpenCode Plugin System            │
                        └─────────────────────────────────────────────┘
                                           │
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TaskPlannerPlugin (index.ts)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Event Handlers:                                                            │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐ │
│  │ tool.execute.before │  │   message.updated   │  │    session.idle     │ │
│  └──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘ │
│             │                        │                        │             │
│             ▼                        ▼                        ▼             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                        Hook Dispatch Layer                           │  │
│  │  • blockDirectEdits()  [Phase 1 - existing]                         │  │
│  │  • guardStateFile()    [Phase 1 - existing]                         │  │
│  │  • validatePhaseOrder()  [Phase 2 - NEW]                            │  │
│  │  • advancePhase()        [Phase 2 - NEW]                            │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                           │
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           StateManager                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Phase 1 (existing):     │ Phase 2 (new):                            │   │
│  │ • load()                │ • getSkippedPhases()                      │   │
│  │ • save()                │ • addSkippedPhase()                       │   │
│  │ • getCurrentPhase()     │ • advancePhase()                          │   │
│  │ • setCurrentPhase()     │ • getPhaseArtifact()                      │   │
│  │ • setPhaseArtifact()    │ • checkArtifactExists()                   │   │
│  │ • withLock()            │ • countClarificationMarkers()             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                           │
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     .opencode/state/active_task_graph.json                  │
│  {                                                                          │
│    "current_phase": "specify",                                              │
│    "phase_artifacts": { "brainstorm": "completed", "specify": "..." },      │
│    "skipped_phases": ["brainstorm"],                                        │
│    ...                                                                      │
│  }                                                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Component Interactions

```
┌──────────────┐     tool="skill"      ┌─────────────────────┐
│   OpenCode   │  ────────────────────▶│ tool.execute.before │
│              │     args.name="X"     └──────────┬──────────┘
└──────────────┘                                  │
                                                  ▼
                                    ┌─────────────────────────┐
                                    │  validatePhaseOrder()   │
                                    │  1. Map skill → phase   │
                                    │  2. Check valid trans.  │
                                    │  3. Check artifacts     │
                                    │  4. Block or allow      │
                                    └─────────────────────────┘
                                                  │
                            ┌─────────────────────┴─────────────────────┐
                            │                                           │
                            ▼                                           ▼
                   ┌────────────────┐                         ┌────────────────┐
                   │  throw Error   │                         │   (continue)   │
                   │  (blocks tool) │                         │   execution    │
                   └────────────────┘                         └────────────────┘


┌──────────────┐   role="assistant"    ┌─────────────────────┐
│   OpenCode   │  ────────────────────▶│   message.updated   │
│              │   content="..."       └──────────┬──────────┘
└──────────────┘                                  │
                                                  ▼
                                    ┌─────────────────────────┐
                                    │    advancePhase()       │
                                    │  1. Check completion    │
                                    │  2. Extract artifact    │
                                    │  3. Count markers       │
                                    │  4. Update state        │
                                    └─────────────────────────┘
                                                  │
                                                  ▼
                                    ┌─────────────────────────┐
                                    │     StateManager        │
                                    │  • advancePhase()       │
                                    │  • setPhaseArtifact()   │
                                    │  • addSkippedPhase()    │
                                    └─────────────────────────┘
```

### 1.3 Data Flow

```
                                  PHASE VALIDATION FLOW
                                  ────────────────────────

  Skill Invocation                    State Lookup                    Validation
  ────────────────                    ────────────                    ──────────

  { tool: "skill",   ────▶  current_phase: "init"    ────▶  "brainstorming" → "brainstorm"
    args: {                 skipped_phases: []               is_valid_transition("init", "brainstorm")
      name: "brainstorming" phase_artifacts: {}              check_artifacts("brainstorm")
    }                                                        ✓ ALLOW
  }

  { tool: "skill",   ────▶  current_phase: "init"    ────▶  "code-implementer" → "execute"
    args: {                 skipped_phases: []               is_valid_transition("init", "execute")
      name: "code-..."      phase_artifacts: {}              ✗ INVALID
    }                                                        throw BLOCKED ERROR
  }


                                 PHASE ADVANCEMENT FLOW
                                 ─────────────────────────

  Message Content                     Pattern Match                   State Update
  ───────────────                     ─────────────                   ────────────

  "...specification     ────▶  PHASE_COMPLETION_PATTERNS   ────▶  Extract artifact path
   complete. Saved               .specify matches!                 Check clarification markers
   to .opencode/..."                                               if markers ≤ 3:
                                                                     addSkippedPhase("clarify")
                                                                     advancePhase("architecture")
                                                                   else:
                                                                     advancePhase("clarify")
```

---

## 2. Component Design

### 2.1 New Hook: `validate-phase-order.ts`

**Purpose:** Intercept skill tool invocations and block those that would skip required phases or violate the workflow order.

**Interface:**

```typescript
/**
 * Validate that a skill invocation respects the phase order.
 * 
 * @param input - The tool execution input from OpenCode
 * @param taskGraph - The current task graph state (null if no orchestration)
 * @throws Error if the skill would violate phase ordering
 */
export function validatePhaseOrder(
  input: ToolExecuteInput,
  taskGraph: TaskGraph | null
): void;

/**
 * Check if a phase transition is valid.
 * 
 * @param from - Current phase
 * @param to - Target phase
 * @param skippedPhases - Phases marked as skipped
 * @returns true if transition is allowed
 */
export function isValidTransition(
  from: Phase,
  to: Phase,
  skippedPhases: Phase[]
): boolean;

/**
 * Check if artifact prerequisites are met for a phase.
 * 
 * @param targetPhase - Phase being transitioned to
 * @param taskGraph - Current task graph
 * @param projectDir - Project directory for file existence checks
 * @returns { valid: boolean; missing?: string }
 */
export function checkArtifactPrerequisites(
  targetPhase: Phase,
  taskGraph: TaskGraph,
  projectDir: string
): { valid: boolean; missing?: string };
```

**Dependencies:**
- `types.ts` - Phase, TaskGraph, ToolExecuteInput
- `constants.ts` - SKILL_TO_PHASE, PHASE_EXEMPT_SKILLS, VALID_TRANSITIONS, ERRORS

**Key Logic:**

```typescript
// Pseudocode
function validatePhaseOrder(input, taskGraph):
  // 1. Exit early if no orchestration active
  if (!taskGraph) return

  // 2. Only check "skill" tool invocations  
  if (input.tool.toLowerCase() !== "skill") return

  // 3. Extract skill name
  const skillName = input.args.name
  if (!skillName) return

  // 4. Check if skill is phase-exempt (utility skills)
  if (PHASE_EXEMPT_SKILLS.includes(skillName)) return

  // 5. Map skill to target phase
  const targetPhase = SKILL_TO_PHASE[skillName]
  
  // 6. Handle unknown skills
  if (!targetPhase) {
    if (taskGraph.current_phase !== "execute") {
      throw new Error(ERRORS.UNKNOWN_SKILL_BLOCKED(skillName))
    }
    return // Allow unknown skills during execute
  }

  // 7. Check transition validity
  const currentPhase = taskGraph.current_phase
  if (!isValidTransition(currentPhase, targetPhase, taskGraph.skipped_phases)) {
    throw new Error(ERRORS.PHASE_ORDER_VIOLATION(currentPhase, targetPhase))
  }

  // 8. Check artifact prerequisites
  const prereq = checkArtifactPrerequisites(targetPhase, taskGraph, projectDir)
  if (!prereq.valid) {
    throw new Error(ERRORS.MISSING_ARTIFACT(targetPhase, prereq.missing))
  }
```

---

### 2.2 New Hook: `advance-phase.ts`

**Purpose:** Detect phase completion via message content patterns and automatically advance the current_phase in state.

**Interface:**

```typescript
/**
 * Check message content for phase completion and advance state.
 * 
 * @param content - Message content from assistant
 * @param taskGraph - Current task graph
 * @param stateManager - State manager for updates
 * @param projectDir - Project directory for file operations
 * @returns Updated phase info or null if no advancement
 */
export async function advancePhase(
  content: string,
  taskGraph: TaskGraph,
  stateManager: StateManager,
  projectDir: string
): Promise<PhaseAdvancement | null>;

/**
 * Detect which phase was completed based on message patterns.
 * 
 * @param content - Message content to analyze
 * @param currentPhase - Current phase for context
 * @returns Detected completed phase or null
 */
export function detectCompletedPhase(
  content: string,
  currentPhase: Phase
): Phase | null;

/**
 * Extract artifact path from message content.
 * 
 * @param content - Message content
 * @returns Extracted file path or "completed" if no path found
 */
export function extractArtifactPath(content: string): string;

/**
 * Count NEEDS CLARIFICATION markers in a spec file.
 * 
 * @param specPath - Path to specification file
 * @returns Number of markers found
 */
export async function countClarificationMarkers(
  specPath: string
): Promise<number>;

/**
 * Return type for phase advancement.
 */
interface PhaseAdvancement {
  completedPhase: Phase;
  newPhase: Phase;
  artifact: string;
  clarifySkipped?: boolean;
}
```

**Dependencies:**
- `types.ts` - Phase, TaskGraph
- `constants.ts` - PHASE_COMPLETION_PATTERNS, ARTIFACT_PATH_PATTERN, CLARIFICATION_MARKER_PATTERN
- `utils/state-manager.ts` - StateManager

**Key Logic:**

```typescript
// Pseudocode
async function advancePhase(content, taskGraph, stateManager, projectDir):
  // 1. Detect completed phase from content
  const completedPhase = detectCompletedPhase(content, taskGraph.current_phase)
  if (!completedPhase) return null

  // 2. Determine next phase
  let nextPhase = getNextPhase(completedPhase)
  let clarifySkipped = false

  // 3. Extract artifact path
  const artifact = extractArtifactPath(content)

  // 4. Special handling for specify → clarify/architecture
  if (completedPhase === "specify") {
    const specPath = resolveArtifactPath(artifact, projectDir)
    const markerCount = await countClarificationMarkers(specPath)
    
    if (markerCount <= 3) {
      await stateManager.addSkippedPhase("clarify")
      nextPhase = "architecture"
      clarifySkipped = true
      console.log("[task-planner] clarify auto-skipped: markers ≤ 3")
    } else {
      nextPhase = "clarify"
    }
  }

  // 5. Update state atomically
  await stateManager.advancePhase(completedPhase, nextPhase, artifact)

  console.log(`[task-planner] Phase advanced: ${completedPhase} → ${nextPhase}`)
  
  return { completedPhase, newPhase: nextPhase, artifact, clarifySkipped }
```

---

### 2.3 Debounce Manager for session.idle

**Purpose:** Prevent rapid re-triggering of phase advancement checks when multiple session.idle events fire.

**Interface:**

```typescript
/**
 * Manages debouncing for session.idle phase checks.
 */
export class PhaseAdvancementDebouncer {
  private lastCheckTimestamp: number = 0;
  private lastContentHash: string = "";
  private readonly debounceMs: number;

  constructor(debounceMs?: number);

  /**
   * Check if we should process this idle event.
   * 
   * @param content - Last message content for deduplication
   * @returns true if processing should proceed
   */
  shouldProcess(content: string): boolean;

  /**
   * Mark that processing completed.
   */
  markProcessed(): void;

  /**
   * Reset the debouncer state.
   */
  reset(): void;
}
```

**Key Logic:**

```typescript
shouldProcess(content: string): boolean {
  const now = Date.now()
  const contentHash = simpleHash(content)
  
  // Skip if same content already processed
  if (contentHash === this.lastContentHash) {
    return false
  }
  
  // Skip if within debounce window
  if (now - this.lastCheckTimestamp < this.debounceMs) {
    return false
  }
  
  this.lastCheckTimestamp = now
  this.lastContentHash = contentHash
  return true
}
```

---

## 3. File Changes

### 3.1 New Files

| File | Purpose |
|------|---------|
| `hooks/validate-phase-order.ts` | Phase validation hook (FR-001 to FR-004, FR-008 to FR-010) |
| `hooks/advance-phase.ts` | Phase advancement hook (FR-005 to FR-007) |
| `utils/debounce.ts` | Session idle debouncing utility |

### 3.2 Modified Files

| File | Changes |
|------|---------|
| `constants.ts` | Add SKILL_TO_PHASE, PHASE_COMPLETION_PATTERNS, PHASE_EXEMPT_SKILLS, VALID_TRANSITIONS, new ERRORS |
| `types.ts` | Add PhaseAdvancement interface, update ToolExecuteInput if needed |
| `utils/state-manager.ts` | Add getSkippedPhases(), addSkippedPhase(), advancePhase(), getPhaseArtifact(), checkArtifactExists(), countClarificationMarkers() |
| `index.ts` | Import and wire up validatePhaseOrder and advancePhase hooks |

### 3.3 Detailed Changes Per File

#### `constants.ts` Additions

```typescript
// ============================================================================
// Skill-to-Phase Mapping (Phase 2)
// ============================================================================

/** Map skill names to their workflow phases */
export const SKILL_TO_PHASE: Record<string, Phase> = {
  "brainstorming": "brainstorm",
  "specify": "specify",
  "clarify": "clarify",
  "architecture-tech-lead": "architecture",
  "task-planner": "decompose",
  "code-implementer": "execute",
  "java-test-engineer": "execute",
  "ts-test-engineer": "execute",
  "nextjs-frontend-design": "execute",
  "security-expert": "execute",
  "k8s-expert": "execute",
  "keycloak-expert": "execute",
  "dotfiles-expert": "execute",
  "spec-check": "execute",
  "review-skill": "execute",
  "wave-gate": "execute",
} as const;

/** Skills exempt from phase validation (utility skills) */
export const PHASE_EXEMPT_SKILLS: readonly string[] = [
  "find-skills",
  "writing-clearly-and-concisely",
  "marketing-ideas",
  "marketing-psychology",
  "copy-editing",
  "copywriting",
  // All marketing-* skills
  "product-marketing-context",
  "content-strategy",
  "social-content",
  "email-sequence",
  "paid-ads",
  "analytics-tracking",
  "seo-audit",
  "schema-markup",
  "programmatic-seo",
  "competitor-alternatives",
  "referral-program",
  "launch-strategy",
  "pricing-strategy",
  "free-tool-strategy",
  "ab-test-setup",
  "popup-cro",
  "form-cro",
  "page-cro",
  "signup-flow-cro",
  "onboarding-cro",
  "paywall-upgrade-cro",
  "ux-conversion",
  "conversion-copy",
] as const;

/** Valid phase transitions */
export const VALID_TRANSITIONS: Record<Phase, Phase[]> = {
  "init": ["brainstorm", "specify"],
  "brainstorm": ["specify"],
  "specify": ["clarify", "architecture"],
  "clarify": ["architecture"],
  "architecture": ["decompose"],
  "decompose": ["execute"],
  "execute": ["execute"],
} as const;

// ============================================================================
// Phase Completion Patterns (Phase 2)
// ============================================================================

/** Patterns to detect phase completion in message content */
export const PHASE_COMPLETION_PATTERNS: Record<Phase, RegExp> = {
  "init": /^$/, // init never "completes" via pattern
  "brainstorm": /(?:brainstorm(?:ing)?|exploration)\s+(?:complete|done|finished)/i,
  "specify": /spec(?:ification)?\s+(?:complete|written|created|saved)/i,
  "clarify": /clarif(?:y|ication)\s+(?:complete|resolved|done)/i,
  "architecture": /(?:architecture|design|plan)\s+(?:complete|done|created)/i,
  "decompose": /(?:decompos(?:e|ition)|tasks?)\s+(?:complete|created|defined)/i,
  "execute": /^$/, // execute phase handled differently
} as const;

/** Pattern to extract artifact file paths from messages */
export const ARTIFACT_PATH_PATTERN = /(?:saved|created|wrote|generated)\s+(?:to\s+)?['"]?([^\s'"]+\.md)['"]?/i;

/** Pattern to count clarification markers in spec files */
export const CLARIFICATION_MARKER_PATTERN = /\[NEEDS CLARIFICATION\]/g;

/** Threshold for auto-skipping clarify phase */
export const CLARIFY_MARKER_THRESHOLD = 3;

/** Allowed artifact path prefixes (for security) */
export const ALLOWED_ARTIFACT_PATHS: readonly RegExp[] = [
  /^\.opencode\/specs\//,
  /^\.opencode\/plans\//,
  /^\.claude\/specs\//,   // Legacy, with deprecation warning
  /^\.claude\/plans\//,   // Legacy, with deprecation warning
] as const;

// ============================================================================
// Debounce Configuration (Phase 2)
// ============================================================================

/** Debounce time for session.idle phase advancement checks (ms) */
export const PHASE_ADVANCEMENT_DEBOUNCE_MS = 500;

// ============================================================================
// Error Messages - Phase 2 Additions
// ============================================================================

// Add to ERRORS object:
export const ERRORS = {
  // ... existing errors ...
  
  UNKNOWN_SKILL_BLOCKED: (skillName: string) =>
    `BLOCKED: Unrecognized skill "${skillName}" during task-planner orchestration.

Current phase requires a recognized workflow skill.
Complete the current phase before using utility skills.

Recognized phase skills:
  brainstorming, specify, clarify, architecture-tech-lead,
  code-implementer, java-test-engineer, ts-test-engineer, etc.`,

  MISSING_ARTIFACT: (phase: Phase, missing: string) =>
    `BLOCKED: Cannot enter ${phase} phase - missing prerequisite.

Required: ${missing}

Complete the prerequisite phase first.`,

  INVALID_ARTIFACT_PATH: (path: string) =>
    `BLOCKED: Invalid artifact path "${path}".

Artifacts must be in:
  .opencode/specs/**/*.md
  .opencode/plans/**/*.md`,

  LEGACY_PATH_WARNING: (path: string) =>
    `WARNING: Legacy .claude/ path detected: ${path}
Consider migrating to .opencode/ directory structure.`,
} as const;
```

#### `utils/state-manager.ts` Additions

```typescript
// Add these methods to StateManager class:

/**
 * Get the list of skipped phases.
 */
async getSkippedPhases(): Promise<Phase[]> {
  const taskGraph = await this.load();
  return taskGraph?.skipped_phases ?? [];
}

/**
 * Add a phase to the skipped phases list.
 */
async addSkippedPhase(phase: Phase): Promise<void> {
  await this.withLock(async () => {
    const taskGraph = await this.loadUnsafe();
    if (!taskGraph) return;

    taskGraph.skipped_phases = taskGraph.skipped_phases ?? [];
    if (!taskGraph.skipped_phases.includes(phase)) {
      taskGraph.skipped_phases.push(phase);
    }
    await this.saveUnsafe(taskGraph);
  });
}

/**
 * Atomically advance to the next phase and record artifact.
 */
async advancePhase(
  completedPhase: Phase,
  nextPhase: Phase,
  artifact: string
): Promise<void> {
  await this.withLock(async () => {
    const taskGraph = await this.loadUnsafe();
    if (!taskGraph) return;

    taskGraph.current_phase = nextPhase;
    taskGraph.phase_artifacts = taskGraph.phase_artifacts ?? {};
    taskGraph.phase_artifacts[completedPhase] = artifact;
    await this.saveUnsafe(taskGraph);
  });
}

/**
 * Get artifact path for a phase.
 */
async getPhaseArtifact(phase: Phase): Promise<string | null> {
  const taskGraph = await this.load();
  return taskGraph?.phase_artifacts?.[phase] ?? null;
}

/**
 * Check if an artifact file exists on disk.
 */
async checkArtifactExists(artifactPath: string, projectDir: string): Promise<boolean> {
  if (!artifactPath || artifactPath === "completed") {
    return true; // "completed" is valid without a file
  }
  
  const fullPath = join(projectDir, artifactPath);
  return existsSync(fullPath);
}
```

#### `index.ts` Modifications

```typescript
// Add imports:
import { validatePhaseOrder } from "./hooks/validate-phase-order.js";
import { advancePhase } from "./hooks/advance-phase.js";
import { PhaseAdvancementDebouncer } from "./utils/debounce.js";

// Add to plugin state:
let phaseDebouncer: PhaseAdvancementDebouncer | null = null;

// Modify event handlers:
export const TaskPlannerPlugin: Plugin = async (ctx: PluginContext) => {
  console.log("[task-planner] Initializing plugin for:", ctx.directory);

  stateManager = new StateManager(ctx.directory);
  phaseDebouncer = new PhaseAdvancementDebouncer();

  return {
    "tool.execute.before": async (input: ToolExecuteInput) => {
      const taskGraph = await getTaskGraph();

      // Check 1: Block direct edits during orchestration
      blockDirectEdits(input, taskGraph);

      // Check 2: Guard state files from Bash writes
      guardStateFile(input, taskGraph);

      // Check 3: Validate phase order for skill invocations [NEW]
      validatePhaseOrder(input, taskGraph, ctx.directory);
    },

    "message.updated": async ({ role, content }) => {
      if (role !== "assistant") return;

      const taskGraph = await getTaskGraph();
      if (!taskGraph) return;
      if (!stateManager) return;

      // Check for phase completion and advance [NEW]
      const result = await advancePhase(
        content,
        taskGraph,
        stateManager,
        ctx.directory
      );

      if (result) {
        invalidateCache(); // Clear cache after state update
      }
    },

    "session.idle": async ({ sessionId }) => {
      const taskGraph = await getTaskGraph();
      if (!taskGraph) return;
      if (!stateManager || !phaseDebouncer) return;

      // Debounce rapid idle events
      const lastMessage = /* get last assistant message */;
      if (!phaseDebouncer.shouldProcess(lastMessage)) {
        return;
      }

      console.log("[task-planner] Session idle detected:", sessionId);

      // Fallback: Check for phase completion if message.updated missed it
      const result = await advancePhase(
        lastMessage,
        taskGraph,
        stateManager,
        ctx.directory
      );

      if (result) {
        invalidateCache();
      }

      phaseDebouncer.markProcessed();
    },

    // ... existing handlers ...
  };
};
```

---

## 4. Data Structures

### 4.1 New Types in `types.ts`

```typescript
/**
 * Result of phase advancement operation.
 */
export interface PhaseAdvancement {
  /** The phase that was completed */
  completedPhase: Phase;
  
  /** The new current phase */
  newPhase: Phase;
  
  /** Path to artifact produced (or "completed" if none) */
  artifact: string;
  
  /** Whether clarify phase was auto-skipped */
  clarifySkipped?: boolean;
}

/**
 * Result of artifact prerequisite check.
 */
export interface ArtifactPrerequisiteResult {
  /** Whether prerequisites are met */
  valid: boolean;
  
  /** Description of missing prerequisite (if invalid) */
  missing?: string;
}

/**
 * Validation result for phase transitions.
 */
export interface PhaseTransitionResult {
  /** Whether transition is allowed */
  allowed: boolean;
  
  /** Reason for blocking (if not allowed) */
  reason?: string;
  
  /** Suggested next steps */
  suggestion?: string;
}
```

### 4.2 Existing Types (No Changes Needed)

The existing `TaskGraph` type already has the required fields:
- `current_phase: Phase`
- `phase_artifacts: Partial<Record<Phase, string | null>>`
- `skipped_phases: Phase[]`

---

## 5. Constants Additions

See Section 3.3 for complete constant additions. Summary:

| Constant | Type | Purpose |
|----------|------|---------|
| `SKILL_TO_PHASE` | `Record<string, Phase>` | Maps skill names to workflow phases |
| `PHASE_EXEMPT_SKILLS` | `string[]` | Skills allowed regardless of phase |
| `VALID_TRANSITIONS` | `Record<Phase, Phase[]>` | Valid from→to phase mappings |
| `PHASE_COMPLETION_PATTERNS` | `Record<Phase, RegExp>` | Patterns to detect phase completion |
| `ARTIFACT_PATH_PATTERN` | `RegExp` | Extracts file paths from messages |
| `CLARIFICATION_MARKER_PATTERN` | `RegExp` | Counts [NEEDS CLARIFICATION] markers |
| `CLARIFY_MARKER_THRESHOLD` | `number` | Threshold for auto-skip (3) |
| `ALLOWED_ARTIFACT_PATHS` | `RegExp[]` | Security: allowed path prefixes |
| `PHASE_ADVANCEMENT_DEBOUNCE_MS` | `number` | Debounce timing (500ms) |

---

## 6. State Manager Extensions

### 6.1 New Methods Summary

| Method | Signature | Purpose |
|--------|-----------|---------|
| `getSkippedPhases()` | `(): Promise<Phase[]>` | Return skipped_phases array |
| `addSkippedPhase(phase)` | `(phase: Phase): Promise<void>` | Add phase to skipped list |
| `advancePhase(completed, next, artifact)` | `(Phase, Phase, string): Promise<void>` | Atomically update phase and artifact |
| `getPhaseArtifact(phase)` | `(phase: Phase): Promise<string \| null>` | Get artifact for a phase |
| `checkArtifactExists(path, projectDir)` | `(string, string): Promise<boolean>` | Check if artifact file exists |

### 6.2 Implementation Notes

1. **Atomic Operations**: `advancePhase()` must update both `current_phase` and `phase_artifacts` within a single lock to prevent race conditions.

2. **Null Safety**: All getters should handle missing/null values gracefully (return empty arrays, null, etc.).

3. **Path Resolution**: `checkArtifactExists()` needs the project directory to resolve relative artifact paths.

---

## 7. Test Strategy

### 7.1 Unit Tests

#### `validate-phase-order.test.ts`

```typescript
describe("validatePhaseOrder", () => {
  describe("when no task graph exists", () => {
    it("allows any skill invocation", () => {});
  });

  describe("when task graph exists", () => {
    describe("skill-to-phase mapping", () => {
      it("maps brainstorming to brainstorm phase", () => {});
      it("maps specify to specify phase", () => {});
      it("maps architecture-tech-lead to architecture phase", () => {});
      it("maps code-implementer to execute phase", () => {});
    });

    describe("valid transitions", () => {
      it("allows init → brainstorm", () => {});
      it("allows init → specify (brainstorm skippable)", () => {});
      it("allows brainstorm → specify", () => {});
      it("allows specify → clarify", () => {});
      it("allows specify → architecture (when clarify skipped)", () => {});
      it("allows clarify → architecture", () => {});
      it("allows architecture → decompose", () => {});
      it("allows decompose → execute", () => {});
      it("allows execute → execute (multiple tasks)", () => {});
    });

    describe("invalid transitions", () => {
      it("blocks init → execute", () => {});
      it("blocks init → architecture", () => {});
      it("blocks brainstorm → architecture", () => {});
      it("blocks specify → execute", () => {});
    });

    describe("artifact prerequisites", () => {
      it("blocks clarify if spec file missing", () => {});
      it("blocks architecture if spec file missing", () => {});
      it("blocks decompose if plan file missing", () => {});
      it("blocks execute if plan file missing", () => {});
    });

    describe("phase-exempt skills", () => {
      it("allows find-skills regardless of phase", () => {});
      it("allows marketing-* skills regardless of phase", () => {});
    });

    describe("unknown skills", () => {
      it("blocks unknown skill during non-execute phase", () => {});
      it("allows unknown skill during execute phase", () => {});
    });
  });
});
```

#### `advance-phase.test.ts`

```typescript
describe("advancePhase", () => {
  describe("completion detection", () => {
    it("detects brainstorm completion", () => {});
    it("detects specify completion", () => {});
    it("detects clarify completion", () => {});
    it("detects architecture completion", () => {});
    it("detects decompose completion", () => {});
    it("returns null for non-completion messages", () => {});
  });

  describe("artifact extraction", () => {
    it("extracts path from 'saved to X' pattern", () => {});
    it("extracts path from 'created X' pattern", () => {});
    it("returns 'completed' when no path found", () => {});
  });

  describe("clarify auto-skip", () => {
    it("skips clarify when markers ≤ 3", () => {});
    it("requires clarify when markers > 3", () => {});
    it("handles missing spec file gracefully", () => {});
  });

  describe("state updates", () => {
    it("advances current_phase", () => {});
    it("records phase artifact", () => {});
    it("adds skipped phase when auto-skipping", () => {});
  });
});
```

#### `debounce.test.ts`

```typescript
describe("PhaseAdvancementDebouncer", () => {
  it("allows first check", () => {});
  it("blocks rapid successive checks", () => {});
  it("allows check after debounce period", () => {});
  it("blocks same content even after debounce", () => {});
  it("allows different content", () => {});
  it("resets state on reset()", () => {});
});
```

### 7.2 Integration Tests

```typescript
describe("Phase Enforcement Integration", () => {
  it("enforces full workflow: init → brainstorm → specify → architecture → decompose → execute", () => {});
  it("allows skipping brainstorm: init → specify", () => {});
  it("auto-skips clarify when markers ≤ 3", () => {});
  it("requires clarify when markers > 3", () => {});
  it("maintains state consistency under concurrent access", () => {});
});
```

### 7.3 Test Utilities

Create `test/fixtures/` with:
- Sample task graph JSON files for different phases
- Sample spec files with varying marker counts
- Mock StateManager for unit tests

---

## 8. Implementation Order

### 8.1 Wave 1: Constants & Types (Parallel)

| Task | Dependencies | Effort |
|------|--------------|--------|
| T1: Add SKILL_TO_PHASE to constants.ts | None | 30min |
| T2: Add PHASE_EXEMPT_SKILLS to constants.ts | None | 15min |
| T3: Add VALID_TRANSITIONS to constants.ts | None | 15min |
| T4: Add PHASE_COMPLETION_PATTERNS to constants.ts | None | 30min |
| T5: Add new ERRORS to constants.ts | None | 30min |
| T6: Add PhaseAdvancement type to types.ts | None | 15min |

### 8.2 Wave 2: State Manager Extensions

| Task | Dependencies | Effort |
|------|--------------|--------|
| T7: Add getSkippedPhases() method | T6 | 15min |
| T8: Add addSkippedPhase() method | T6 | 20min |
| T9: Add advancePhase() method | T6 | 30min |
| T10: Add getPhaseArtifact() method | None | 15min |
| T11: Add checkArtifactExists() method | None | 20min |

### 8.3 Wave 3: Debounce Utility

| Task | Dependencies | Effort |
|------|--------------|--------|
| T12: Create utils/debounce.ts | None | 45min |
| T13: Write debounce.test.ts | T12 | 30min |

### 8.4 Wave 4: validate-phase-order Hook

| Task | Dependencies | Effort |
|------|--------------|--------|
| T14: Create hooks/validate-phase-order.ts skeleton | T1-T5 | 30min |
| T15: Implement isValidTransition() | T3, T14 | 30min |
| T16: Implement checkArtifactPrerequisites() | T10, T11, T14 | 45min |
| T17: Implement validatePhaseOrder() main function | T1, T2, T15, T16 | 1h |
| T18: Write validate-phase-order.test.ts | T17 | 1.5h |

### 8.5 Wave 5: advance-phase Hook

| Task | Dependencies | Effort |
|------|--------------|--------|
| T19: Create hooks/advance-phase.ts skeleton | T4, T9 | 30min |
| T20: Implement detectCompletedPhase() | T4, T19 | 30min |
| T21: Implement extractArtifactPath() | T4, T19 | 20min |
| T22: Implement countClarificationMarkers() | T19 | 30min |
| T23: Implement advancePhase() main function | T7-T9, T20-T22 | 1h |
| T24: Write advance-phase.test.ts | T23 | 1.5h |

### 8.6 Wave 6: Plugin Integration

| Task | Dependencies | Effort |
|------|--------------|--------|
| T25: Update index.ts with new imports | T17, T23 | 15min |
| T26: Wire validatePhaseOrder into tool.execute.before | T25 | 30min |
| T27: Wire advancePhase into message.updated | T12, T25 | 30min |
| T28: Wire advancePhase fallback into session.idle | T12, T25 | 30min |
| T29: Write integration tests | T26-T28 | 1.5h |

### 8.7 Wave 7: Polish & Documentation

| Task | Dependencies | Effort |
|------|--------------|--------|
| T30: Add console logging for debugging | T26-T28 | 30min |
| T31: Verify all existing Phase 1 tests pass | T26-T28 | 30min |
| T32: Manual testing with real OpenCode | T31 | 1h |

---

## 9. Dependency Graph

```
                    ┌───────────────────────────────────────────────┐
                    │              Wave 1 (Parallel)                │
                    │   T1  T2  T3  T4  T5  T6                      │
                    └───────────────────┬───────────────────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
              ▼                         ▼                         ▼
┌─────────────────────────┐ ┌─────────────────────────┐ ┌─────────────────────────┐
│      Wave 2             │ │      Wave 3             │ │ (start Wave 4 partial)  │
│ T7  T8  T9  T10  T11    │ │      T12  T13           │ │        T14              │
└───────────┬─────────────┘ └───────────┬─────────────┘ └───────────┬─────────────┘
            │                           │                           │
            └───────────────────────────┼───────────────────────────┘
                                        │
                                        ▼
                    ┌───────────────────────────────────────────────┐
                    │              Wave 4                           │
                    │   T15  T16  T17  T18                          │
                    └───────────────────┬───────────────────────────┘
                                        │
                                        ▼
                    ┌───────────────────────────────────────────────┐
                    │              Wave 5                           │
                    │   T19  T20  T21  T22  T23  T24                │
                    └───────────────────┬───────────────────────────┘
                                        │
                                        ▼
                    ┌───────────────────────────────────────────────┐
                    │              Wave 6                           │
                    │   T25  T26  T27  T28  T29                     │
                    └───────────────────┬───────────────────────────┘
                                        │
                                        ▼
                    ┌───────────────────────────────────────────────┐
                    │              Wave 7                           │
                    │   T30  T31  T32                               │
                    └───────────────────────────────────────────────┘
```

---

## 10. Risk Mitigation

| Risk | Mitigation |
|------|------------|
| OpenCode "skill" tool structure differs from assumption | Test early with real OpenCode; add logging to capture actual input structure |
| session.idle fires too frequently | Debouncer with content hashing prevents duplicate processing |
| message.updated misses completion signals | session.idle as fallback; comprehensive pattern list |
| Concurrent phase advancement attempts | All state updates use withLock() |
| Legacy .claude/ paths break validation | Allow .claude/ paths with deprecation warning |
| Spec file not accessible during validation | Graceful fallback; allow if file read fails |

---

## 11. Open Implementation Questions

### Q1: How to get last message content in session.idle?

**Options:**
1. Store messages in plugin state via message.updated events
2. Check if OpenCode context provides message history
3. Use a separate in-memory buffer

**Recommendation:** Option 1 - maintain a single-message buffer updated on every message.updated, cleared on advancement.

### Q2: Should PHASE_EXEMPT_SKILLS be configurable?

**Recommendation:** No for Phase 2. Keep as constants. Consider config file in later phase if needed.

### Q3: Case sensitivity for skill names?

**Recommendation:** Case-insensitive matching using `.toLowerCase()` on both sides of the lookup.

---

## 12. Success Criteria

Phase 2 is complete when:

1. [ ] All unit tests pass for validate-phase-order.ts
2. [ ] All unit tests pass for advance-phase.ts
3. [ ] All integration tests pass
4. [ ] All existing Phase 1 tests continue to pass
5. [ ] Manual test: Can complete full workflow in OpenCode
6. [ ] Manual test: Invalid phase transitions are blocked with clear errors
7. [ ] Manual test: Clarify auto-skip works correctly
8. [ ] No `any` types in new code
9. [ ] All error messages follow ERRORS constant pattern

---

## Appendix A: Full SKILL_TO_PHASE Mapping

```typescript
export const SKILL_TO_PHASE: Record<string, Phase> = {
  // Brainstorm phase
  "brainstorming": "brainstorm",
  
  // Specify phase
  "specify": "specify",
  
  // Clarify phase
  "clarify": "clarify",
  
  // Architecture phase
  "architecture-tech-lead": "architecture",
  
  // Decompose phase
  "task-planner": "decompose",
  
  // Execute phase (implementation skills)
  "code-implementer": "execute",
  "java-test-engineer": "execute",
  "ts-test-engineer": "execute",
  "nextjs-frontend-design": "execute",
  "security-expert": "execute",
  "k8s-expert": "execute",
  "keycloak-expert": "execute",
  "dotfiles-expert": "execute",
  "remotion-best-practices": "execute",
  "vercel-react-best-practices": "execute",
  
  // Execute phase (review/validation skills)
  "spec-check": "execute",
  "review-skill": "execute",
  "wave-gate": "execute",
} as const;
```

---

## Appendix B: Error Message Examples

**Phase Order Violation:**
```
BLOCKED: Cannot skip to phase "execute" from "init".

The task-planner requires phases to be completed in order:
  init → brainstorm → specify → clarify → architecture → decompose → execute

Current phase: init
Attempted: code-implementer → execute

Next step: Run brainstorming or specify skill first.
```

**Missing Artifact:**
```
BLOCKED: Cannot enter architecture phase - missing prerequisite.

Required: specify (no spec.md found)

Complete the specify phase first, or ensure spec file exists at the expected location.
```

**Unknown Skill During Orchestration:**
```
BLOCKED: Unrecognized skill "my-custom-skill" during task-planner orchestration.

Current phase requires a recognized workflow skill.
Complete the current phase before using utility skills.

Recognized phase skills:
  brainstorming, specify, clarify, architecture-tech-lead,
  code-implementer, java-test-engineer, ts-test-engineer, etc.
```
