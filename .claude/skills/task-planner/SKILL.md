---
name: task-planner
version: "2.0.0"
description: "This skill should be used when the user asks to 'plan this', 'orchestrate', 'break down', 'split into phases', 'coordinate tasks', 'create a plan', 'multi-step feature', or has complex tasks needing structured decomposition. Decomposes work into wave-based parallel tasks, assigns specialized agents, creates GitHub Issue for tracking, and manages execution through automated hooks."
---

# Task Planner - Orchestration Skill

Orchestrates multi-step implementations: decomposition, agent assignment, wave scheduling, GitHub Issue tracking, hook-based execution management.

**This is an ORCHESTRATION skill** - delegates design to `/architecture-tech-lead`, implementation to appropriate agents. Never implement code directly.

---

## Arguments

- `/task-planner "description"` - Start new plan
- `/task-planner --status` - Show current task graph status
- `/task-planner --complete` - Finalize, clean up state
- `/task-planner --abort` - Cancel mid-execution, clean state

---

## Workflow

### 1. Parse Intent

Understand what user wants to achieve:
- What is the goal?
- What are success criteria?
- What codebase areas involved?

### 2. Analyze Complexity

**Simple** (decompose directly):
- Clear scope, <3 tasks
- No architecture decisions needed
- Single feature addition

**Complex** (delegate to arch-lead):
- Multiple components affected
- Architecture decisions required
- Design patterns to choose
- >3 implementation tasks

For complex tasks:
```
Invoke: /architecture-tech-lead
Result: Detailed plan with architecture, code examples, phases
Output: .claude/plans/{YYYY-MM-DD}-{slug}.md
```

### 3. Extract Implementation Tasks

Parse plan into tasks. **Design = the plan itself, NOT a tracked task**. Tasks start at implementation:

```
T1: Create User domain model (+ tests)
T2: Implement JWT service (+ tests)
T3: Add login endpoint (+ tests)
```

**Sizing heuristics** - decompose further if:
- Task touches >5 files
- Multiple unrelated concerns in one task
- Description needs "and" to explain

### 4. Assign Agents

Match task keywords to wrapper agents (these preload the corresponding skills):

| Agent (subagent_type) | Triggers |
|-------|----------|
| code-implementer-agent | implement, create, build, add, write code, model |
| architecture-agent | design, architecture, pattern, refactor |
| java-test-agent | test, junit, jqwik, property-based (Java) |
| ts-test-agent | vitest, playwright, react test (TypeScript) |
| security-agent | security, auth, jwt, oauth, vulnerability |
| code-reviewer | review, quality check |
| dotfiles-agent | nix, nixos, home-manager, sops |
| k8s-agent | kubernetes, k8s, kubectl, helm, argocd, deploy, pod, ingress, service, external-secrets, cert-manager, metallb, cloudflared |
| keycloak-agent | keycloak, realm, oidc, abac, authorization services |
| frontend-agent | frontend, ui, react, next.js, component, styling |

Fallback: `general-purpose` (Task tool's built-in agent with all tools) if no keyword match.

### 5. Schedule Waves

Dependency-based wave scheduling:

```
Wave 1: Tasks with no dependencies (run parallel)
Wave 2: Tasks depending on Wave 1
Wave N: Tasks depending on Wave N-1
```

Example:
```
Wave 1: [T1: User model + tests, T2: JWT service + tests]  (parallel)
Wave 2: [T3: Login endpoint + tests]                       (depends on T1, T2)
```

**Note:** Each task includes its own tests (per agent template constraints). Don't create separate "write tests" tasks - tests are part of implementation.

### 6. User Approval

Present plan summary:
- Task breakdown with agents
- Wave schedule
- GitHub Issue will be created

Ask: "Proceed with this plan?"

### 7. Create Artifacts

On approval, create three artifacts:

**A. Local Plan** (already exists from arch-lead or step 2):
```
.claude/plans/{YYYY-MM-DD}-{slug}.md
```

**B. GitHub Issue**:
```bash
gh issue create \
  --title "Plan: {title}" \
  --body "$(cat .claude/plans/{YYYY-MM-DD}-{slug}.md)"
```

Store returned issue number.

**C. State File**: `.claude/state/active_task_graph.json`

See `templates.md` for full schema. Key fields:
- `current_wave`, `executing_tasks`, `tasks[]` (id, status, wave, tests_passed, test_evidence, review_status)
- `wave_gates[N]` (impl_complete, tests_passed, reviews_complete, blocked)

**Per-task automated fields** (set by SubagentStop hooks, not manually):
- `tests_passed` — extracted from agent transcript by `update-task-status.sh`
- `test_evidence` — description of what test markers were found
- `review_status` — set by `store-reviewer-findings.sh` when review agent completes

**Status Transitions:**
- `pending` → `in_progress`: Task spawned to agent
- `in_progress` → `implemented`: Agent finished (SubagentStop hook also extracts test evidence)
- `implemented` → `completed`: Wave gate passed (test evidence + review + no critical findings)

### 8. Orchestrate Execution

For each wave:

1. Get pending tasks in current wave
2. Spawn ALL wave tasks in parallel (single message, multiple Task calls):
   - Update state: add to `executing_tasks`, `status = "in_progress"`
   - Build agent prompt with context (see Agent Context Template)
   - SubagentStop hook: status → "implemented", extracts test evidence from transcript
3. Wait for all wave tasks to reach "implemented"
4. Run **Wave Gate Sequence** (see 8a) before advancing

### 8a. Wave Gate Sequence

After all wave tasks reach "implemented", the SubagentStop hook outputs a prompt to run `/wave-gate`. **Invoke `/wave-gate`** — see its SKILL.md for full sequence (test verification, parallel review, gate advancement).

If blocked, fix issues and run `/wave-gate` again — it re-reviews only blocked tasks.

---

## Agent Context Template

See `templates.md` for full template. Key elements:
- `**Task ID:** TX` (required for hooks to track)
- Task description + relevant plan context
- Constraints: follow plan, write tests, tests must pass

---

## State Management

### On `/task-planner "description"`:
1. Create `.claude/state/active_task_graph.json`
2. Hooks become active (they check for this file)

### On `/task-planner --status`:
Read state file and display formatted summary:
```
Plan: Issue #42 - Add user authentication
Wave 2/3 | 2 completed, 1 in progress

[✓] T1: Create User model (code-implementer) — tests: PASS
[✓] T2: JWT service (code-implementer) — tests: PASS
[→] T3: Login endpoint (code-implementer) — tests: pending

Legend: [✓] completed  [→] in_progress  [ ] pending
```

### On `/task-planner --complete`:
1. Verify all tasks completed
2. Optionally close GitHub Issue
3. Remove `.claude/state/active_task_graph.json`
4. Hooks deactivate

### On `/task-planner --abort`:
1. Ask: close issue or leave open?
2. Remove `.claude/state/active_task_graph.json`
3. Hooks deactivate

### Branch Strategy

Tasks execute on the **current branch**. Recommended workflow:
- Create a feature branch before starting: `feature/{slug}`
- All wave agents commit on this branch
- After all waves complete, PR from feature branch to main
- `/task-planner --complete` can trigger `/finalize` for branch + PR

If already on a feature branch when invoking `/task-planner`, execution continues there.

### Modifying Plan Mid-Execution

To add/remove/modify tasks:
1. Edit `active_task_graph.json` - add task to `tasks[]`, set correct `wave`
2. Update GH Issue - add/edit checkbox line matching task ID
3. If adding to current wave, task runs in next spawn cycle

Cannot modify tasks already `in_progress` or `completed`.

---

## GitHub Issue Format

See `templates.md` for full format. Key requirements:
- Checkbox tasks: `- [ ] T1: description` (hooks update these)
- Wave groupings with dependencies noted
- Execution order table

---

## Hook Integration

Hooks auto-activate when `active_task_graph.json` exists:

| Hook | Event | Purpose |
|------|-------|---------|
| `block-direct-edits.sh` | PreToolUse: Edit/Write | BLOCKS direct file edits — forces Task tool |
| `guard-state-file.sh` | PreToolUse: Bash | BLOCKS writes to state files — allows reads |
| `validate-task-execution.sh` | PreToolUse: Task | Validates wave order + dependency resolution |
| `update-task-status.sh` | SubagentStop | Marks "implemented" + extracts test evidence |
| `store-reviewer-findings.sh` | SubagentStop | Parses review findings + sets review_status |
| `validate-review-invoker.sh` | SubagentStop | Verifies /review-pr transcript evidence |
| `mark-subagent-active.sh` | SubagentStart | Flags active subagent for Edit/Write allow |
| `cleanup-subagent-flag.sh` | SubagentStop | Cleans up subagent flag |

**Enforcement chain:**
- Test evidence: agent runs tests → `update-task-status.sh` extracts from transcript → `complete-wave-gate.sh` verifies
- Review status: review agent runs → `store-reviewer-findings.sh` sets status → `complete-wave-gate.sh` verifies
- State file: `guard-state-file.sh` blocks Bash writes, `block-direct-edits.sh` blocks Edit/Write
- Only hooks (SubagentStop) and whitelisted helpers can modify state

---

## Observability & Debugging

**State inspection:**
- State file: `.claude/state/active_task_graph.json`
- View current state: `jq '.' .claude/state/active_task_graph.json`
- Per-task status: `jq '.tasks[] | {id, status, tests_passed, review_status}' .claude/state/active_task_graph.json`
- Check executing tasks: `jq '.executing_tasks' .claude/state/active_task_graph.json`

**Common symptoms:**

| Symptom | Likely Cause | Diagnosis |
|---------|-------------|-----------|
| Task stuck in `in_progress` | Agent crashed/timed out | Check `executing_tasks` array; re-spawn if empty but status is `in_progress` |
| Hook not triggering | State file missing | Verify `.claude/state/active_task_graph.json` exists |
| Checkbox not updating | Task ID mismatch | Compare task ID in state vs GH issue format (`- [ ] T1:`) |
| Wave not advancing | Gate blocked | Check `wave_gates[N].blocked` and `reviews_complete` |
| `tests_passed` missing | SubagentStop hook didn't parse markers | Re-spawn agent; ensure tests produce recognizable output |
| `review_status` stuck "pending" | Review agent type mismatch or hook parse failed | Check hook fired; re-spawn reviewer |
| State write blocked | `guard-state-file.sh` active | Use helper scripts, not direct jq writes |

**Debugging steps:**
1. Run `/task-planner --status` for formatted view
2. Inspect raw state file for detailed status
3. Check hook scripts exist in `~/.claude/hooks/`
4. Verify GH issue matches state file task IDs

---

## Error Recovery

| Failure | Recovery |
|---------|----------|
| Agent crashes mid-task | Re-spawn same task; state shows `in_progress` |
| Agent completes but wrong impl | Mark task `pending`, update prompt with corrections, re-spawn |
| Agent completes but no test evidence | Re-spawn agent — must run tests with recognizable output |
| Parallel agents edit same file | Resolve conflicts manually, mark affected tasks `pending` |
| GH issue create fails | Retry `gh issue create`; continue without if persistent |
| State file corrupted | Rebuild from GH issue checkboxes + local plan file |
| Wave gate blocked | Fix issues, run `/wave-gate` again (re-reviews blocked only). See "Fixing Blocked Waves" below |
| Tests fail repeatedly | Ask user: fix tests, skip task, or abort plan |
| Hook script fails | Check script permissions (`chmod +x`), verify shebang |
| Context lost between waves | Reference completed task files in new task prompts |

### Fixing Blocked Waves

When a wave is blocked (critical review findings), Edit/Write are also blocked by `block-direct-edits.sh`. To fix issues:

1. **Re-spawn via Task tool** — create a fix agent with the blocked task context and critical findings. The agent (subagent) CAN use Edit/Write. Prompt it with the specific findings to address.
2. **After fixes**, run `/wave-gate` again — it re-reviews only blocked tasks.
3. **Emergency bypass** — remove `.claude/state/active_task_graph.json`, fix manually, rebuild state from GH issue + plan file.

---

## Plan Limits

**Recommended boundaries:**
- **Max tasks per plan:** 8-12 tasks (beyond this, split into sub-plans)
- **Max waves:** 4-5 waves (deeper dependency chains = higher failure risk)
- **Max parallel tasks per wave:** 4-6 (more = harder to track/debug)

**When to split into multiple plans:**
- Total tasks exceed 12
- Multiple independent features bundled together
- Different teams/owners for different parts
- Risk of context loss in long-running orchestration

**Token budget awareness:**
- Each agent spawn consumes context tokens
- Large plans may exhaust context before completion
- Prefer smaller focused plans over monolithic ones

---

## Constraints

- **ALL implementation via Task tool** - Edit/Write blocked by hook
- **ALL state writes via hooks/helpers** - Bash writes blocked by guard
- Delegate design to /architecture-tech-lead for complex tasks
- Must get user approval before creating issue
- Must populate TodoWrite with task breakdown
- Task IDs must match `- [ ] T1:` format in issue for checkbox updates
- Only ONE active plan at a time (state file is singleton)

---

## CRITICAL: Parallel Execution

**Multiple Task calls in ONE message** = parallel execution within wave.

Each Task call needs: subagent_type, description, prompt with `**Task ID:** TX`
