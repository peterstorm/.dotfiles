# Claude Hooks → OpenCode Plugins Conversion Plan

**Created:** 2026-02-03  
**Status:** Planning  
**Skill:** task-planner  

---

## Executive Summary

The task-planner skill relies on **14 hook scripts** and **10 helper utilities** that need to be converted from Bash shell scripts to TypeScript plugins for OpenCode. The conversion is feasible because OpenCode's plugin system has equivalent events, but requires architectural changes around state management and cross-repo coordination.

---

## 1. Hook Inventory & Event Mapping

### Claude Hook Events → OpenCode Plugin Events

| Claude Event | OpenCode Event | Notes |
|--------------|----------------|-------|
| `PreToolUse` | `tool.execute.before` | ✅ Direct equivalent |
| `PostToolUse` | `tool.execute.after` | ✅ Direct equivalent |
| `SubagentStart` | `session.created` | ⚠️ Partial - OpenCode uses agents differently |
| `SubagentStop` | `session.idle` / `session.status` | ⚠️ Partial - need to detect agent completion |
| `SessionStart` | `server.connected` | ✅ Can use for cleanup |

### Hooks to Convert

| # | Hook File | Claude Event | Purpose | OpenCode Mapping |
|---|-----------|--------------|---------|------------------|
| 1 | `block-direct-edits.sh` | PreToolUse | Block Edit/Write during orchestration | `tool.execute.before` → throw Error |
| 2 | `guard-state-file.sh` | PreToolUse | Block Bash writes to state files | `tool.execute.before` → check command |
| 3 | `validate-task-execution.sh` | PreToolUse | Enforce wave order + dependencies | `tool.execute.before` → check agent spawn |
| 4 | `validate-phase-order.sh` | PreToolUse | Enforce brainstorm→specify→arch flow | `tool.execute.before` → check phase |
| 5 | `mark-subagent-active.sh` | SubagentStart | Track active agents, store paths | `session.created` |
| 6 | `update-task-status.sh` | SubagentStop | Mark tasks "implemented" | `session.idle` + `message.updated` |
| 7 | `advance-phase.sh` | SubagentStop | Move current_phase forward | `session.idle` |
| 8 | `store-reviewer-findings.sh` | SubagentStop | Parse review output, store findings | `session.idle` |
| 9 | `store-spec-check-findings.sh` | SubagentStop | Parse spec-check output | `session.idle` |
| 10 | `verify-new-tests.sh` | SubagentStop | Check git diff for new test methods | `session.idle` |
| 11 | `cleanup-subagent-flag.sh` | SubagentStop | Clean up temp tracking files | `session.idle` |
| 12 | `validate-review-invoker.sh` | SubagentStop | Validate review was properly invoked | `session.idle` |
| 13 | `cleanup-stale-subagents.sh` | SessionStart | Clean old tracking files | `server.connected` |

---

## 2. Architectural Challenges & Solutions

### Challenge 1: SubagentStop Equivalent

**Problem:** Claude Code has explicit `SubagentStop` event when a spawned agent finishes. OpenCode doesn't have a direct equivalent.

**Solution Options:**

| Option | Approach | Pros | Cons |
|--------|----------|------|------|
| A | Use `session.idle` | Fires when no active work | May fire prematurely |
| B | Use `message.updated` + detect completion | Monitor for completion signals | Complex parsing |
| C | Use custom tool that agents call at end | Explicit completion marker | Requires agent discipline |
| **D (Recommended)** | Combination: `session.idle` + task ID tracking | Reliable, works with parallel agents | Slightly more complex |

### Challenge 2: Agent Type Detection

**Problem:** Claude Code hooks receive `agent_type` in input. OpenCode doesn't have equivalent metadata for "which skill/agent is running."

**Solution:** 
- Track agent context in state when spawning via custom tool
- Use message content patterns to infer agent type
- Add explicit markers in agent prompts that get captured

### Challenge 3: Cross-Repo State Access

**Problem:** Claude hooks use `/tmp/claude-subagents/{session_id}.task_graph` for cross-repo access.

**Solution:**
- OpenCode plugins have access to `project` and `directory` context
- Store state path in plugin-scoped memory (not temp files)
- Use OpenCode's client SDK for persistent state

### Challenge 4: Transcript Parsing

**Problem:** Claude Code provides `agent_transcript_path` (JSONL file). OpenCode doesn't expose raw transcripts.

**Solution:**
- Use `message.updated` events to capture messages as they arrive
- Build transcript in memory during session
- Use `session.idle` to process complete transcript

---

## 3. State Management Redesign

### Current (Claude): File-based JSON state

```
.claude/state/active_task_graph.json
/tmp/claude-subagents/{session_id}.*
```

### Proposed (OpenCode): Hybrid approach

```typescript
// Plugin-scoped state (in-memory + file persistence)
interface TaskPlannerState {
  taskGraph: TaskGraph | null;
  activeAgents: Map<string, AgentContext>;
  messageBuffer: Message[];
}

// File persistence (same location, just managed by plugin)
// .opencode/state/active_task_graph.json
```

### State File Location Change

```
.claude/state/ → .opencode/state/
.claude/specs/ → .opencode/specs/
.claude/plans/ → .opencode/plans/
```

---

## 4. Helper Utilities to Convert

| # | Helper | Language | OpenCode Approach |
|---|--------|----------|-------------------|
| 1 | `extract-task-id.sh` | Bash→TS | Simple regex function |
| 2 | `lock.sh` | Bash→TS | Use async mutex or file lock library |
| 3 | `parse-transcript.sh` | Python→TS | Parse JSONL → use message events instead |
| 4 | `parse-files-modified.sh` | Python→TS | Track via `file.edited` events |
| 5 | `resolve-task-graph.sh` | Bash→TS | Plugin context provides paths |
| 6 | `complete-wave-gate.sh` | Bash→TS | Inline in wave-gate logic |
| 7 | `mark-tests-passed.sh` | Bash→TS | Inline state update |
| 8 | `store-review-findings.sh` | Bash→TS | Inline state update |
| 9 | `detect-test-requirement.sh` | Bash→TS | Simple pattern matching |
| 10 | `suggest-spec-anchors.sh` | Bash→TS | Regex matching against spec |

---

## 5. Plugin File Structure

```
.opencode/plugins/
├── task-planner/
│   ├── index.ts              # Main plugin entry point
│   ├── hooks/
│   │   ├── block-direct-edits.ts
│   │   ├── guard-state-file.ts
│   │   ├── validate-task-execution.ts
│   │   ├── validate-phase-order.ts
│   │   ├── update-task-status.ts
│   │   ├── advance-phase.ts
│   │   ├── store-findings.ts
│   │   └── verify-new-tests.ts
│   ├── utils/
│   │   ├── extract-task-id.ts
│   │   ├── lock.ts
│   │   ├── state-manager.ts
│   │   └── git-utils.ts
│   ├── types.ts              # TypeScript interfaces
│   └── constants.ts
```

---

## 6. Implementation Phases

### Phase 1: Foundation (Priority: Critical)

**Goal:** Core state management and blocking hooks

| Task | Effort | Dependencies |
|------|--------|--------------|
| Create TypeScript types for TaskGraph, Task, WaveGate | 2h | None |
| Implement state-manager.ts (read/write/lock) | 3h | Types |
| Implement `block-direct-edits.ts` | 1h | State manager |
| Implement `guard-state-file.ts` | 1h | State manager |
| Test blocking behavior | 1h | Above |

**Deliverable:** Edits blocked when task graph active

### Phase 2: Phase Enforcement (Priority: High)

**Goal:** Enforce brainstorm→specify→architecture flow

| Task | Effort | Dependencies |
|------|--------|--------------|
| Implement `validate-phase-order.ts` | 2h | Phase 1 |
| Implement `advance-phase.ts` | 2h | Phase 1 |
| Implement phase detection logic | 1h | Above |
| Test phase transitions | 1h | Above |

**Deliverable:** Phase ordering enforced

### Phase 3: Task Execution (Priority: High)

**Goal:** Wave-based parallel execution with dependency checking

| Task | Effort | Dependencies |
|------|--------|--------------|
| Implement `validate-task-execution.ts` | 3h | Phase 1 |
| Implement `update-task-status.ts` | 3h | Phase 1 |
| Implement test evidence extraction | 2h | Above |
| Test wave progression | 2h | Above |

**Deliverable:** Tasks execute in correct wave order

### Phase 4: Review & Quality Gates (Priority: Medium)

**Goal:** Capture review findings and enforce quality

| Task | Effort | Dependencies |
|------|--------|--------------|
| Implement `store-reviewer-findings.ts` | 2h | Phase 3 |
| Implement `store-spec-check-findings.ts` | 2h | Phase 3 |
| Implement `verify-new-tests.ts` | 3h | Phase 3 |
| Test wave-gate flow | 2h | Above |

**Deliverable:** Reviews captured, gates enforced

### Phase 5: Polish & Edge Cases (Priority: Low)

**Goal:** Cleanup, cross-session handling

| Task | Effort | Dependencies |
|------|--------|--------------|
| Implement session cleanup | 1h | All |
| Add error recovery mechanisms | 2h | All |
| Add logging/debugging | 1h | All |
| Documentation | 2h | All |

**Deliverable:** Production-ready plugin

---

## 7. Sample Plugin Code

### Main Plugin Entry Point

```typescript
// .opencode/plugins/task-planner/index.ts
import type { Plugin } from "@opencode-ai/plugin"
import { StateManager } from "./utils/state-manager"
import { blockDirectEdits } from "./hooks/block-direct-edits"
import { guardStateFile } from "./hooks/guard-state-file"
import { validateTaskExecution } from "./hooks/validate-task-execution"
import { validatePhaseOrder } from "./hooks/validate-phase-order"
import { updateTaskStatus } from "./hooks/update-task-status"
import { advancePhase } from "./hooks/advance-phase"

export const TaskPlannerPlugin: Plugin = async (ctx) => {
  const stateManager = new StateManager(ctx.directory)
  
  return {
    // Block direct edits during orchestration
    "tool.execute.before": async (input, output) => {
      const taskGraph = await stateManager.load()
      if (!taskGraph) return // No active plan
      
      // Check for Edit/Write blocking
      await blockDirectEdits(input, output, taskGraph)
      
      // Check for state file writes via bash
      await guardStateFile(input, output, taskGraph)
      
      // Validate task execution order
      await validateTaskExecution(input, output, taskGraph, stateManager)
      
      // Validate phase order
      await validatePhaseOrder(input, output, taskGraph)
    },
    
    // Update state when session goes idle (agent completed)
    "session.idle": async ({ session }) => {
      const taskGraph = await stateManager.load()
      if (!taskGraph) return
      
      // Update task status based on session content
      await updateTaskStatus(session, taskGraph, stateManager)
      
      // Advance phase if applicable
      await advancePhase(session, taskGraph, stateManager)
    },
    
    // Track file edits for new-test verification
    "file.edited": async ({ path }) => {
      const taskGraph = await stateManager.load()
      if (!taskGraph) return
      
      // Track which files were modified
      await stateManager.trackFileEdit(path)
    },
  }
}
```

### Block Direct Edits Hook

```typescript
// .opencode/plugins/task-planner/hooks/block-direct-edits.ts
import type { TaskGraph } from "../types"

export async function blockDirectEdits(
  input: { tool: string; args: Record<string, unknown> },
  output: { args: Record<string, unknown> },
  taskGraph: TaskGraph
): Promise<void> {
  // Only block if task graph is active
  if (!taskGraph) return

  const blockedTools = ["edit", "write"]
  
  if (blockedTools.includes(input.tool.toLowerCase())) {
    throw new Error(
      `BLOCKED: Direct edits not allowed during task-planner orchestration.

Use the agent tool with appropriate agent for implementation:
  - code-implementer-agent for production code
  - java-test-agent or ts-test-agent for tests
  - frontend-agent for UI components

This ensures proper phase sequencing and review gates.`
    )
  }
}
```

### State Manager

```typescript
// .opencode/plugins/task-planner/utils/state-manager.ts
import { readFile, writeFile, mkdir } from "fs/promises"
import { existsSync } from "fs"
import { join, dirname } from "path"
import type { TaskGraph, Task } from "../types"

export class StateManager {
  private statePath: string
  private lockPath: string
  private filesModified: Set<string> = new Set()

  constructor(projectDir: string) {
    this.statePath = join(projectDir, ".opencode/state/active_task_graph.json")
    this.lockPath = join(projectDir, ".opencode/state/.task_graph.lock")
  }

  async load(): Promise<TaskGraph | null> {
    if (!existsSync(this.statePath)) return null
    
    try {
      const content = await readFile(this.statePath, "utf-8")
      return JSON.parse(content) as TaskGraph
    } catch {
      return null
    }
  }

  async save(taskGraph: TaskGraph): Promise<void> {
    await this.withLock(async () => {
      const dir = dirname(this.statePath)
      if (!existsSync(dir)) {
        await mkdir(dir, { recursive: true })
      }
      
      taskGraph.updated_at = new Date().toISOString()
      await writeFile(this.statePath, JSON.stringify(taskGraph, null, 2))
    })
  }

  async updateTask(taskId: string, updates: Partial<Task>): Promise<void> {
    await this.withLock(async () => {
      const taskGraph = await this.load()
      if (!taskGraph) return
      
      taskGraph.tasks = taskGraph.tasks.map(task => 
        task.id === taskId ? { ...task, ...updates } : task
      )
      
      await this.save(taskGraph)
    })
  }

  async trackFileEdit(path: string): Promise<void> {
    this.filesModified.add(path)
  }

  getFilesModified(): string[] {
    return Array.from(this.filesModified)
  }

  clearFilesModified(): void {
    this.filesModified.clear()
  }

  private async withLock<T>(fn: () => Promise<T>): Promise<T> {
    // Simple file-based locking
    const maxAttempts = 50
    let attempt = 0
    
    while (existsSync(this.lockPath)) {
      attempt++
      if (attempt >= maxAttempts) {
        throw new Error("Could not acquire lock after 50 attempts")
      }
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    
    try {
      await writeFile(this.lockPath, process.pid.toString())
      return await fn()
    } finally {
      try {
        const { unlink } = await import("fs/promises")
        await unlink(this.lockPath)
      } catch {
        // Ignore cleanup errors
      }
    }
  }
}
```

### TypeScript Types

```typescript
// .opencode/plugins/task-planner/types.ts

export type TaskStatus = "pending" | "in_progress" | "implemented" | "completed" | "cancelled"
export type Phase = "init" | "brainstorm" | "specify" | "clarify" | "architecture" | "decompose" | "execute"

export interface Task {
  id: string                      // e.g., "T1", "T2"
  description: string
  wave: number
  status: TaskStatus
  agent: string                   // e.g., "code-implementer-agent"
  depends_on: string[]
  spec_anchors?: string[]
  new_tests_required?: boolean
  
  // Set by hooks
  start_sha?: string
  tests_passed?: boolean
  test_evidence?: string
  new_tests_written?: boolean
  new_test_evidence?: string
  review_status?: "pending" | "passed" | "blocked" | "evidence_capture_failed"
  critical_findings?: string[]
  advisory_findings?: string[]
  files_modified?: string[]
}

export interface WaveGate {
  impl_complete?: boolean
  tests_passed?: boolean
  reviews_complete?: boolean
  blocked?: boolean
}

export interface SpecCheck {
  wave: number
  run_at: string
  critical_count: number
  high_count: number
  critical_findings: string[]
  high_findings: string[]
  medium_findings: string[]
  verdict: "PASSED" | "BLOCKED" | "EVIDENCE_CAPTURE_FAILED" | "UNKNOWN"
}

export interface TaskGraph {
  // Plan metadata
  title: string
  spec_file: string
  plan_file: string
  github_issue?: number
  
  // Phase tracking
  current_phase: Phase
  phase_artifacts: Record<Phase, string | null>
  skipped_phases: Phase[]
  
  // Wave execution
  current_wave: number
  tasks: Task[]
  executing_tasks: string[]
  wave_gates: Record<number, WaveGate>
  
  // Quality checks
  spec_check?: SpecCheck
  
  // Timestamps
  created_at: string
  updated_at: string
}

export interface AgentContext {
  agentId: string
  agentType: string
  taskId?: string
  startedAt: string
}
```

---

## 8. Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| OpenCode events don't fire in expected order | High | Medium | Add defensive checks, log everything |
| Can't detect agent completion reliably | High | Low | Use multiple signals (idle + patterns) |
| State corruption from parallel writes | Medium | Medium | Use file locking + atomic writes |
| Performance impact from hook processing | Low | Low | Async processing, minimal blocking |
| OpenCode plugin API changes | Medium | Low | Pin to specific version, add abstraction layer |

---

## 9. Testing Strategy

### Unit Tests
- Each hook function in isolation
- State manager read/write operations
- Task ID extraction patterns
- Phase transition validation

### Integration Tests
- Full phase flow with mock OpenCode context
- Wave progression with dependencies
- Review findings capture and storage

### E2E Tests
- Run actual task-planner flow in OpenCode
- Multi-task parallel execution
- Error recovery scenarios

### Regression Tests
- Ensure parity with Claude Code behavior
- Compare state file outputs

---

## 10. Migration Checklist

### Pre-Migration
- [ ] Backup existing `.claude/` state files
- [ ] Document any custom modifications to hooks
- [ ] Verify OpenCode version supports required events

### During Migration
- [ ] Create `.opencode/plugins/task-planner/` structure
- [ ] Implement Phase 1 (foundation)
- [ ] Test blocking behavior works
- [ ] Implement remaining phases incrementally

### Post-Migration
- [ ] Update SKILL.md to reference OpenCode paths
- [ ] Update any hardcoded `.claude/` references
- [ ] Test full workflow end-to-end
- [ ] Remove old Claude hooks (or keep for dual support)

---

## 11. Open Questions

1. **Does OpenCode's `session.idle` fire reliably?**
   - Need to test with parallel agent spawns

2. **Can we access session/message history from plugins?**
   - Required for transcript-like functionality

3. **How does OpenCode handle plugin errors?**
   - Does throwing an Error actually block the tool?

4. **Is there a way to detect which "agent" or "skill" is running?**
   - May need custom markers in prompts

---

## 12. References

### Source Files (Claude Hooks)
- `~/.claude/hooks/PreToolUse/*.sh`
- `~/.claude/hooks/SubagentStop/*.sh`
- `~/.claude/hooks/SubagentStart/*.sh`
- `~/.claude/hooks/SessionStart/*.sh`
- `~/.claude/hooks/helpers/*.sh`

### OpenCode Documentation
- [Plugins Documentation](https://opencode.ai/docs/plugins)
- [Custom Tools](https://opencode.ai/docs/custom-tools)
- [Agent Skills](https://opencode.ai/docs/skills)

### Task Planner Skill
- `~/.claude/skills/task-planner/SKILL.md`
- `~/.claude/skills/task-planner/templates/*.md`
