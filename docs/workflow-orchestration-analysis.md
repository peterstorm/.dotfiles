# Workflow Orchestration Analysis

Analysis of [barkain/claude-code-workflow-orchestration](https://github.com/barkain/claude-code-workflow-orchestration) and how to adopt its patterns.

## Their Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         HOOKS                                    │
├──────────────────┬─────────────────┬─────────────────┬──────────┤
│ UserPromptSubmit │   PreToolUse    │  SubagentStop   │ Session  │
│ (clear state)    │ (gate tools)    │ (verify+todo)   │ Start    │
└──────────────────┴─────────────────┴─────────────────┴──────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      TASK PLANNER SKILL                          │
│  - Decomposes tasks into subtasks                                │
│  - Assigns agents via keyword matching                           │
│  - Groups into parallel waves                                    │
│  - Outputs task graph + TodoWrite entries                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     SPECIALIZED AGENTS (8)                       │
│  tech-lead-architect | codebase-context-analyzer                 │
│  task-completion-verifier | code-cleanup-optimizer               │
│  code-reviewer | devops-experience-architect                     │
│  documentation-expert | dependency-manager                       │
└─────────────────────────────────────────────────────────────────┘
```

**Key insight:** Hooks enforce the workflow, task-planner orchestrates, agents execute.

---

## Hook Patterns

### 1. PreToolUse - Tool Gating

**Their implementation:** Block Write/Edit/Bash unless `/delegate` was called first.

```bash
# Allowlist pattern - these always pass
ALLOWED_TOOLS="AskUserQuestion|TodoWrite|Skill|Task"

# State tracking
.claude/state/delegation_active    # flag file
.claude/state/delegated_sessions   # session IDs
.claude/state/active_delegations.json  # parallel tracking
```

**Adaptation for our setup:**

```bash
# .claude/hooks/PreToolUse/enforce-skill-usage.sh
# Force /code-implementer before writing code

TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')

# Allow research tools freely
[[ "$TOOL_NAME" =~ ^(Read|Glob|Grep|WebFetch|WebSearch|AskUserQuestion|TodoWrite)$ ]] && exit 0

# Check if implementation skill was invoked
if [[ ! -f ".claude/state/implementation_active" ]]; then
  echo "Use /code-implementer before writing code"
  exit 2
fi
```

### 2. SessionStart - Context Injection

**Their implementation:** Inject ~27k char orchestrator prompt on every session.

**Adaptation for our setup:**

```bash
# .claude/hooks/SessionStart/inject-architecture.sh
# Inject architecture rules into every session

cat <<'EOF'
<architecture-context>
## Active Session Rules
- FP style, immutability first
- Push I/O to edges
- 90%+ unit testable without mocks
- Use Either for error handling
</architecture-context>
EOF
```

### 3. SubagentStop - Post-Execution QA

**Their implementation:** Auto-spawn verifier agent after task completion.

**Adaptation for our setup:**

```bash
# .claude/hooks/SubagentStop/auto-review.sh
# Spawn code-reviewer after implementation agents

AGENT_TYPE="${SUBAGENT_TYPE:-unknown}"
AGENT_STATUS="${SUBAGENT_STATUS:-unknown}"

[[ "$AGENT_STATUS" != "completed" ]] && exit 0

# Skip if already a reviewer
[[ "$AGENT_TYPE" =~ (reviewer|verifier|analyzer) ]] && exit 0

echo "Implementation complete. Spawning code-reviewer for QA..."
```

### 4. UserPromptSubmit - State Cleanup

**Their implementation:** Clear all delegation state between prompts.

```bash
# .claude/hooks/UserPromptSubmit/clear-state.sh
rm -f .claude/state/implementation_active
rm -f .claude/state/active_task_graph.json
```

---

## Building Our Own Task Planner

### Core Concept

Task planner = decomposition + assignment + scheduling

```
Input: "Add user auth with JWT"
                │
                ▼
┌─────────────────────────────────┐
│        DECOMPOSITION            │
│  1. Design auth flow            │
│  2. Create user model           │
│  3. Implement JWT service       │
│  4. Add login endpoint          │
│  5. Add middleware              │
│  6. Write tests                 │
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│        AGENT ASSIGNMENT         │
│  1 → architecture-tech-lead     │
│  2 → code-implementer           │
│  3 → code-implementer           │
│  4 → code-implementer           │
│  5 → code-implementer           │
│  6 → java-test-engineer         │
└─────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────┐
│        WAVE SCHEDULING          │
│  Wave 1: [1]        (design)    │
│  Wave 2: [2,3]      (parallel)  │
│  Wave 3: [4,5]      (parallel)  │
│  Wave 4: [6]        (tests)     │
└─────────────────────────────────┘
```

### Their Agent Assignment Algorithm

Keyword-based scoring (agent scores ≥2 matches wins):

```
architecture-tech-lead:
  keywords: [design, architecture, pattern, best practice, structure]

code-implementer:
  keywords: [implement, create, add, build, write code]

java-test-engineer:
  keywords: [test, junit, jqwik, coverage, assert]

security-expert:
  keywords: [auth, security, jwt, oauth, keycloak, vulnerability]
```

Fallback to `general-purpose` if no agent scores ≥2.

### Minimal Task Planner Skill

```markdown
---
description: Decompose tasks, assign agents, schedule waves
tools: [Read, Glob, Grep, Bash, AskUserQuestion, TodoWrite]
---

# Task Planner

## Process

1. **Parse Intent**
   - What is the user trying to achieve?
   - What are the success criteria?
   - Any ambiguities requiring clarification?

2. **Explore Codebase**
   - Find relevant files/patterns
   - Identify integration points
   - Note existing conventions

3. **Decompose**
   - Break into atomic subtasks
   - Each subtask = single responsibility
   - Identify dependencies between tasks

4. **Assign Agents**
   Match keywords to available agents:
   | Agent | Triggers |
   |-------|----------|
   | architecture-tech-lead | design, pattern, structure |
   | code-implementer | implement, create, build |
   | java-test-engineer | test, junit, property |
   | ts-test-engineer | vitest, playwright, react test |
   | security-expert | auth, jwt, keycloak |
   | code-reviewer | review, quality, check |

5. **Schedule Waves**
   - Wave 1: Tasks with no dependencies
   - Wave N: Tasks depending on Wave N-1
   - Maximize parallelism per wave

6. **Output**
   - Task table with: ID, description, agent, dependencies, wave
   - JSON task graph for hooks to validate
   - TodoWrite entries for tracking

## Output Format

### Task Table
| ID | Task | Agent | Depends | Wave |
|----|------|-------|---------|------|
| T1 | Design auth flow | architecture-tech-lead | - | 1 |
| T2 | Create user model | code-implementer | T1 | 2 |

### Task Graph JSON
```json
{
  "tasks": [
    {"id": "T1", "agent": "architecture-tech-lead", "deps": [], "wave": 1},
    {"id": "T2", "agent": "code-implementer", "deps": ["T1"], "wave": 2}
  ],
  "current_wave": 1
}
```

Save to `.claude/state/active_task_graph.json` for hook validation.

## Constraints
- Never implement code
- Only explore for planning context
- Must populate TodoWrite before returning
```

### Wave Validation Hook

```bash
# .claude/hooks/PreToolUse/validate-wave.sh
# Ensure tasks execute in wave order

TASK_GRAPH=".claude/state/active_task_graph.json"
[[ ! -f "$TASK_GRAPH" ]] && exit 0

TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name')
[[ "$TOOL_NAME" != "Task" ]] && exit 0

# Extract phase from prompt
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.tool_input.prompt // empty')
PHASE_ID=$(echo "$PROMPT" | grep -oE 'Phase ID: (T[0-9]+)' | cut -d' ' -f3)

[[ -z "$PHASE_ID" ]] && {
  echo "Task invocation missing Phase ID"
  exit 2
}

# Check wave order
CURRENT_WAVE=$(jq -r '.current_wave' "$TASK_GRAPH")
TASK_WAVE=$(jq -r ".tasks[] | select(.id==\"$PHASE_ID\") | .wave" "$TASK_GRAPH")

[[ "$TASK_WAVE" -gt "$CURRENT_WAVE" ]] && {
  echo "Cannot execute $PHASE_ID (wave $TASK_WAVE) - current wave is $CURRENT_WAVE"
  exit 2
}
```

---

## Implementation Roadmap

### Phase 1: Hooks Foundation
- [ ] `SessionStart/inject-context.sh` - inject architecture rules
- [ ] `UserPromptSubmit/clear-state.sh` - reset between prompts
- [ ] State directory: `.claude/state/`

### Phase 2: Skill Enforcement
- [ ] `PreToolUse/enforce-skills.sh` - gate Write/Edit behind skills
- [ ] Track skill invocation in state files
- [ ] Allowlist for research tools

### Phase 3: Task Planner Skill
- [ ] Create `.claude/skills/task-planner/SKILL.md`
- [ ] Agent keyword mapping
- [ ] Wave scheduling algorithm
- [ ] Task graph JSON output

### Phase 4: Wave Orchestration
- [ ] `PreToolUse/validate-wave.sh` - enforce execution order
- [ ] `SubagentStop/advance-wave.sh` - progress tracking
- [ ] `SubagentStop/auto-verify.sh` - spawn reviewers

---

## Differences from Their Approach

| Aspect | Theirs | Ours |
|--------|--------|------|
| Philosophy | Strict enforcement via hooks | Skill-based guidance |
| Parallelism | Wave-based concurrent agents | Sequential with optional parallel |
| Agent breadth | 8 general agents | Domain-specific (keycloak, security) |
| /delegate cmd | Required for all tool use | Optional orchestration |

Our setup has deeper domain expertise but less orchestration automation. Task planner + hooks would add the automation layer while keeping specialized skills.

---

## References

- [Original repo](https://github.com/barkain/claude-code-workflow-orchestration)
- [Claude Code hooks docs](https://docs.anthropic.com/en/docs/claude-code/hooks)
- [Plugin development guide](https://docs.anthropic.com/en/docs/claude-code/plugins)
