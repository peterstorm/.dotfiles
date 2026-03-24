---
name: opencode-task-planner
description: "This skill should be used when the user asks to 'plan this', 'orchestrate', 'break down', 'split into phases', 'coordinate tasks', 'create a plan', 'multi-step feature', or has complex tasks needing structured decomposition. Decomposes work into wave-based parallel tasks, assigns specialized agents, creates GitHub Issue for tracking, and manages execution through phase artifacts on disk."
---

# Task Planner - Full Orchestration Skill

Orchestrates the COMPLETE feature lifecycle: brainstorm -> specify -> clarify -> architecture -> plan-alignment -> decompose -> execute.

**This is the SINGLE ENTRY POINT** for multi-step features. Spawns specialized agents for autonomous phases; drives interactive phases (brainstorm, clarify) directly via the question tool.

**Interactive vs Agent-driven phases:**
- **Orchestrator-driven (interactive):** Brainstorm, Clarify -- require multi-turn user input, so the orchestrator (you) asks questions directly using the `question` tool, writes artifacts, and tracks progress via artifact files on disk.
- **Agent-driven (autonomous):** Specify, Architecture, Plan-Alignment, Decompose, Execute -- produce artifacts autonomously, orchestrator verifies artifacts exist before advancing.

**Progress tracking:** The orchestrator tracks the current phase in conversation context. Artifact files on disk serve as the source of truth for phase completion. No external state file is used.

---

## Arguments

- `/task-planner "description"` - Start new plan (runs full flow)
- `/task-planner --skip-brainstorm` - Skip brainstorm phase (scope already clear)
- `/task-planner --skip-clarify` - Skip clarify phase (accept markers as-is)
- `/task-planner --skip-specify` - Skip brainstorm/specify/clarify (use existing spec)
- `/task-planner --skip-plan-alignment` - Skip plan-alignment phase (proceed directly to decompose)

**Note:** All phases are MANDATORY by default. Skip flags allow explicit bypass with user acknowledgment.

**Clarify threshold:** Markers > 3 triggers mandatory clarify phase.

---

## Full Orchestration Flow

```
/task-planner "feature description"
        |
        v
+---------------------------------------------------------+
| Phase 0: BRAINSTORM [MANDATORY]                         |
|   Driver: ORCHESTRATOR (interactive Q&A with user)      |
|   Output: .claude/specs/{slug}/brainstorm.md            |
|   Skip: --skip-brainstorm                               |
+---------------------------------------------------------+
        |
        v
+---------------------------------------------------------+
| Phase 1: SPECIFY [MANDATORY]                            |
|   Agent: specify-agent                                  |
|   Output: .claude/specs/{slug}/spec.md                  |
+---------------------------------------------------------+
        |
        v (if >3 markers, else skip to ARCHITECTURE)
+---------------------------------------------------------+
| Phase 2: CLARIFY [MANDATORY if markers > 3]             |
|   Driver: ORCHESTRATOR (interactive Q&A with user)      |
|   Output: Updated spec.md with resolved uncertainties   |
|   Skip: --skip-clarify                                  |
+---------------------------------------------------------+
        |
        v
+---------------------------------------------------------+
| Phase 3: ARCHITECTURE                                   |
|   Agent: architecture-agent                             |
|   Output: .claude/plans/{slug}.md                       |
+---------------------------------------------------------+
        |
        v
+---------------------------------------------------------+
| Phase 3.5: PLAN ALIGNMENT                               |
|   Agent: plan-alignment-agent                           |
|   Output: .claude/specs/{slug}/plan-alignment.md        |
|   Skip: --skip-plan-alignment                           |
|   Loop: gaps found -> re-run architecture (with context)|
+---------------------------------------------------------+
        |
        v
+---------------------------------------------------------+
| Phase 4: DECOMPOSE                                      |
|   Agent: decompose-agent                                |
|   Output: Task graph JSON + GitHub Issue                 |
+---------------------------------------------------------+
        |
        v
+---------------------------------------------------------+
| Phase 5: EXECUTE (wave by wave)                         |
|   Spawn impl agents -> wave-gate -> advance             |
|   Output: Working implementation                        |
+---------------------------------------------------------+
```

---

## Phase Tracking

Progress is tracked by **artifact files on disk**. Before advancing to any phase, verify its prerequisites exist:

| Phase | Prerequisite Artifacts |
|-------|----------------------|
| specify | `brainstorm.md` exists OR `--skip-brainstorm` |
| clarify | `spec.md` exists with >3 markers |
| architecture | `spec.md` exists with markers <= 3 OR `--skip-clarify` |
| plan-alignment | Plan file exists at `.claude/plans/{slug}.md` |
| decompose | Plan file exists + `plan-alignment.md` exists OR `--skip-plan-alignment` |
| execute | Task graph defined (from decompose output) |

The orchestrator maintains a mental model of the current phase in conversation context and advances by verifying artifacts, not by writing to a state file.

---

## Phase 0: Brainstorm (MANDATORY -- Orchestrator-Driven)

**Always run** unless `--skip-brainstorm` flag provided.

**This phase is INTERACTIVE.** The orchestrator (you) drives it directly -- do NOT spawn a brainstorm-agent. Subagents cannot have multi-turn conversations with the user.

### Steps:

1. **Explore the codebase** using the `explore` agent (Task tool) or direct search tools to gather context about existing code, architecture, dependencies, and constraints.

2. **Ask the user questions** using the `question` tool. Cover these areas:
   - Why are they building/changing this? (motivation, pain points)
   - What constraints exist? (timeline, compatibility, team skills)
   - What preferences do they have? (frameworks, tools, approaches)
   - What's the scope boundary? (what's in, what's out)
   - Any prior decisions already made?

   Ask questions in batches of 3-5 using the `question` tool. Multiple rounds are fine -- iterate until the feature scope is clear.

3. **Synthesize findings** into a brainstorm document. Use `templates/phase-brainstorm.md` as the artifact format guide.

4. **Write the artifact** to `.claude/specs/{date_slug}/brainstorm.md`.

5. **Present summary** to user and ask:
   > "Approach: {selected approach}. Proceed to specification?"

   If user wants changes -> revise the brainstorm document.

6. **Advance** once approved. Brainstorm is complete when `brainstorm.md` exists on disk and the user has confirmed.

---

## Phase 1: Specify

**Always run** (unless `--skip-specify` or spec already exists).

**Spawn specify-agent** with context from `templates/phase-specify.md`.

Substitute variables:
- `{feature_description}` - Refined description (from brainstorm or original)
- `{date_slug}` - `YYYY-MM-DD-feature-name` format

**Wait for agent completion.** Extract:
- Spec file path
- Count of `[NEEDS CLARIFICATION]` markers

If markers > 3: Proceed to Phase 2.
If markers <= 3: Skip to Phase 3.

---

## Phase 2: Clarify (MANDATORY if markers > 3 -- Orchestrator-Driven)

**Run if:** spec has >3 `[NEEDS CLARIFICATION]` markers. Skip via `--skip-clarify` if accepting markers as-is.

**This phase is INTERACTIVE.** The orchestrator (you) drives it directly -- do NOT spawn a clarify-agent. Subagents cannot have multi-turn conversations with the user.

### Steps:

1. **Read the spec file** and extract all `[NEEDS CLARIFICATION]` markers.

2. **Present markers to the user** and ask them to resolve each one using the `question` tool. Group related markers into single questions where possible. For each marker, provide:
   - The marker text and context from the spec
   - Proposed options (if you can infer reasonable choices)
   - A "Type your own answer" escape hatch (enabled by default in the question tool)

3. **Edit the spec file** to replace each `[NEEDS CLARIFICATION]` marker with the user's decision. Use clear, definitive language -- the resolved text should read as a firm requirement, not a question.

4. **Verify** the spec has zero remaining markers:
   ```bash
   grep -c "NEEDS CLARIFICATION" <spec_file_path>
   ```

5. **Advance** once all markers are resolved. Clarify is complete when `spec.md` has <= 3 markers.

If still >3 markers after user input: Ask user to resolve remaining, or proceed with caveats and `--skip-clarify` acknowledgment.

---

## Phase 3: Architecture

**Always run.**

**Spawn architecture-agent** with context from `templates/phase-architecture.md`.

Substitute variables:
- `{feature_description}` - Feature name/description
- `{spec_file_path}` - Path to spec from Phase 1
- `{date_slug}` - `YYYY-MM-DD-feature-name` format

**Wait for agent completion.** Extract:
- Plan file path (should be at `.claude/plans/{slug}.md`)
- Implementation phases

Verify the plan file exists on disk before advancing.

---

## Phase 3.5: Plan Alignment

**Always run** (unless `--skip-plan-alignment` flag provided).

**Spawn plan-alignment-agent** with context from `templates/phase-plan-alignment.md`.

Substitute variables:
- `{spec_file_path}` - Path to spec from Phase 1
- `{plan_file_path}` - Path to plan from Phase 3
- `{spec_dir}` - Spec directory (e.g. `.claude/specs/{date_slug}`)

**Wait for agent completion.** Read gap report at `.claude/specs/{slug}/plan-alignment.md`.

**If gaps found:** Present gap report to user. Ask:
> "N gaps found. Re-run architecture with this feedback, or proceed to decompose?"

- **If re-run:** Delete the stale gap report, re-spawn architecture-agent with gap report appended to prompt as additional context. When architecture completes, re-run plan-alignment.
- **If proceed:** Continue to Phase 4.

**Loop-back warning:** If the user has chosen to re-run architecture 2 or more times, warn: "This is loop-back attempt N. Consider proceeding to decompose or refining the spec directly."

**If no gaps:** Proceed to Phase 4.

**Note:** The gap report is always written (even when no gaps). Its existence at `.claude/specs/{slug}/plan-alignment.md` is required to gate decompose entry.

---

## Phase 4: Decompose

**Spawn decompose-agent** with context from `templates/phase-decompose.md`.

Substitute variables:
- `{feature_description}` - Feature name/description
- `{spec_file_path}` - Path to spec from Phase 1
- `{plan_file_path}` - Path to plan from Phase 3

**Wait for agent completion.** Agent outputs pure JSON task graph.

### 4a. Validate Output

Verify the decompose output contains valid JSON with:
- `tasks` array with `id`, `description`, `agent`, `wave`, `depends_on` for each task
- `total_waves` count
- Each task has `spec_anchors` linking to spec requirements

If output is malformed -> re-spawn decompose-agent with error details.

### 4b. User Approval

Present plan summary:
- Spec path
- Plan path
- Task breakdown with agents
- Wave schedule
- GitHub Issue will be created

Ask: "Proceed with this plan?"

### 4c. Create Artifacts

On approval:

**A. Save task graph** to `.claude/specs/{slug}/task-graph.json`.

**B. GitHub Issue:**
```bash
gh issue create --title "Plan: {title}" --body "$(cat <<'EOF'
## Plan: {title}

### Task Breakdown

#### Wave 1: {description} (parallel)
- [ ] T1: {task description}
- [ ] T2: {task description}

#### Wave 2: {description} (depends on Wave 1)
- [ ] T3: {task description}

### Execution Order

| ID | Task | Agent | Wave | Depends |
|----|------|-------|------|---------|
| T1 | ... | code-implementer-agent | 1 | - |

### Verification Checklist
- [ ] All tests pass
- [ ] No security vulnerabilities
- [ ] Code reviewed
EOF
)"
```

---

## Phase 5: Execute

The orchestrator manages execution using the task graph from Phase 4. Track task status in conversation context.

### Task Status Transitions

```
pending -> in_progress    (task spawned to agent)
in_progress -> implemented (agent completes successfully)
in_progress -> failed      (agent fails or produces broken code)
failed -> in_progress      (retry, max 2 attempts)
implemented -> completed   (wave gate passed)
```

### For each wave:

1. **Identify pending tasks** for the current wave from the task graph
2. **Spawn ALL wave tasks in parallel** (single message, multiple Task calls)
3. **Wait for all to complete**
4. **If any tasks failed:** re-spawn with error context (max 2 retries per task)
5. **Run wave gate:** invoke `/opencode-wave-gate` (test + spec-check + review)
6. **If passed:** mark wave tasks as completed, advance to next wave
7. **If blocked:** fix issues, re-run `/opencode-wave-gate`

**Agent context:** Use `templates/impl-agent-context.md` for each task.

Substitute variables:
- `{task_id}`, `{wave}`, `{agent_type}`, `{dependencies}`
- `{task_description}` - From task breakdown
- `{spec_anchors_formatted}` - Formatted anchor list with requirement text
- `{plan_context}` - Relevant section from plan
- `{file_list}` - Files to create/modify
- `{plan_file_path}` - Path to full plan

### Tracking Progress

After each wave completes, update the GitHub Issue:
- Check off completed task checkboxes
- Add a comment with wave completion status and any issues encountered

---

## Quick Start Examples

### Full flow (recommended):
```
/task-planner "Add user authentication with email/password"
```
Runs: brainstorm -> specify -> clarify -> arch -> plan-alignment -> decompose -> execute

### Skip to architecture (spec exists):
```
/task-planner --skip-specify "Add user authentication"
```
Runs: arch -> plan-alignment -> decompose -> execute (uses existing spec)

### Simple feature (clear scope):
```
/task-planner "Add logout button to navbar"
```
Detects simple -> may skip brainstorm, minimal spec

---

## Error Recovery

| Failure | Recovery |
|---------|----------|
| Brainstorm incomplete | Ask more questions, revise brainstorm.md |
| Specify agent too technical | Re-spawn with "focus on WHAT not HOW" |
| Clarify -- user can't resolve markers | Accept caveats with `--skip-clarify`, or narrow scope |
| Architecture agent off-spec | Re-spawn referencing spec requirements |
| Plan-alignment gaps unresolvable | Use `--skip-plan-alignment` or manually amend plan before proceeding |
| Implementation agent fails tests | Re-spawn with error context (max 2 retries) |
| Wave gate blocked | Fix issues, re-run `/opencode-wave-gate` |

---

## Plan Limits

- **Max tasks:** 8-12 (split if larger)
- **Max waves:** 4-5
- **Max parallel tasks per wave:** 4-6

---

## CRITICAL: Phase Execution Model

**Interactive phases (orchestrator-driven):** brainstorm, clarify
- The orchestrator asks the user questions via the `question` tool
- Writes artifact files directly
- Advances by verifying artifact exists on disk
- These phases CANNOT be delegated to subagents (subagents cannot interact with the user)

**Autonomous phases (agent-driven):** specify, architecture, plan-alignment, decompose
- Each spawns ONE agent via the Task tool
- Agent writes artifact, orchestrator verifies artifact exists before advancing

**Parallel execution (execute phase):** T1, T2, T3 in same message

Pass context forward between phases via artifact files.

---

## Artifact Locations Summary

| Artifact | Path |
|----------|------|
| Brainstorm | `.claude/specs/{slug}/brainstorm.md` |
| Specification | `.claude/specs/{slug}/spec.md` |
| Plan alignment report | `.claude/specs/{slug}/plan-alignment.md` |
| Architecture plan | `.claude/plans/{slug}.md` |
| Task graph | `.claude/specs/{slug}/task-graph.json` |
