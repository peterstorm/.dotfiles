# GSD (Get Shit Done) Patterns for Loom

Analysis of [gsd-build/get-shit-done](https://github.com/gsd-build/get-shit-done) — a meta-prompting and context engineering framework for Claude Code — and how its patterns apply to our loom orchestration system.

---

## TL;DR — Condensed Summary

### What GSD Is

Prompt-engineering-heavy, artifact-driven framework. 6-stage cycle: init → discuss → plan → execute → verify → complete. Solves context rot via fresh 200K windows per agent, structured artifacts (PROJECT.md, STATE.md, REQUIREMENTS.md, ROADMAP.md), and goal-backward verification. No hooks — all enforcement is prompt-level.

### Core Architectural Difference

| | **Loom** | **GSD** |
|---|----------|---------|
| Enforcement | Hooks + chmod 444 (OS-level) | Prompt instructions only |
| State | JSON state machine | Markdown files (100-line STATE.md cap) |
| Scope | Feature-level orchestration | Full project lifecycle |
| Trust model | Capable-but-untrustworthy (hook-enforced) | Smart-but-forgetful (artifact-persistent) |

### Top 4 Ideas to Steal

1. **Discussion/Gray-Area Phase** — structured ambiguity resolution before planning. Outputs locked decisions/discretion/deferred buckets. Fills brainstorm→specify weakness already identified in loom review.
2. **Plan Validation Agent** — 7-dimension pre-execution check (requirement coverage, dependency correctness, scope sanity, etc). Loom only validates JSON schema, not whether plan achieves goals.
3. **Goal-Backward Verification** — 4-level substance check (exists → substantive → wired → functional) + anti-stub detection. Extends wave gate beyond tests+review.
4. **Executor Deviation Rules** — graduated autonomy (auto-fix bugs/deps, escalate structural changes). Structured protocol for unexpected situations during execution.

### Secondary Ideas

5. Quick mode (`--quick` flag for lightweight tasks)
6. Checkpoint protocol during execution (human-verify/decision/human-action)
7. Performance metrics (duration per task/wave/phase)
8. Atomic commit enforcement per task (verify commit between start_sha and HEAD)
9. Model profiles per agent type (opus/sonnet/haiku mapping)
10. Compressed summaries per plan (GSD's SUMMARY.md = our clnode work_summary pattern)

### What Loom Already Does Better

- Hook enforcement (OS-level > prompt-level)
- Machine-readable state (JSON > markdown parsing)
- Spec traceability (automated anchor suggestion)
- New test verification (git diff scan for test patterns)
- Review integration (per-wave code review + spec-check)

### Adoption Roadmap

```
Phase 1 (Quick Wins): Quick mode, deviation rules template, atomic commit check
Phase 2 (High Impact): Discussion phase, plan validation, goal-backward verification
Phase 3 (Polish): Checkpoints, metrics, model profiles, compressed summaries
```

---

## Extended Analysis

### What GSD Is

A lightweight meta-prompting and context engineering framework for Claude Code, OpenCode, and Gemini CLI. Addresses "context rot" — quality degradation as Claude fills its context window — through spec-driven development with structured artifacts.

**6-stage development cycle:**
```
/gsd:new-project  →  Deep questioning, parallel research, requirements, roadmap
/gsd:discuss-phase →  Gray area identification, user decisions, CONTEXT.md
/gsd:plan-phase   →  Task decomposition, plan checker validation, PLAN.md
/gsd:execute-phase →  Wave-based parallel execution, fresh context per agent
/gsd:verify-work  →  Goal-backward verification, substance checks
/gsd:complete-milestone →  Archive, tag, loop to next phase
```

**Key artifacts maintained:**

| Artifact | Purpose | Size Discipline |
|----------|---------|-----------------|
| `PROJECT.md` | Vision, always available | Stable after init |
| `REQUIREMENTS.md` | Scoped v1/v2 requirements with REQ-IDs | Phase traceability |
| `ROADMAP.md` | Progress tracking, completed phases | Updated per phase |
| `STATE.md` | Decisions, blockers, session memory | **100-line limit** |
| `PLAN.md` | Atomic XML tasks per plan | ~50% context budget |
| `CONTEXT.md` | Discussion decisions (locked/discretion/deferred) | Per-phase |
| `SUMMARY.md` | Execution record per plan | Committed to git |

**Agent ecosystem (11 agents):**
- `gsd-project-researcher` — 4 parallel researchers (stack, features, architecture, pitfalls)
- `gsd-research-synthesizer` — Combines research into SUMMARY.md
- `gsd-roadmapper` — Derives phases from requirements
- `gsd-planner` — Task decomposition with goal-backward methodology
- `gsd-plan-checker` — Pre-execution plan validation (7 dimensions)
- `gsd-executor` — Task execution with deviation handling + checkpoints
- `gsd-verifier` — Post-execution goal-backward verification
- `gsd-debugger` — Scientific root cause analysis with persistent state
- `gsd-codebase-mapper` — Brownfield convention discovery
- `gsd-integration-checker` — Cross-component wiring validation

### Architecture Comparison — Deep Dive

#### Phase Flow Mapping

```
GSD                         Loom                        Delta
───────────────────         ───────────────────         ─────────
new-project (research)      brainstorm                  GSD: 4 parallel researchers
                                                        Loom: single agent
discuss-phase               (no equivalent)             GSD: structured gray areas
                                                        Loom: GAP — weakest handoff
plan-phase                  specify + architecture      GSD: plan checker validates
  + plan-checker            + decompose                 Loom: schema-only validation
execute-phase               execute (waves)             Similar wave-based parallel
                                                        GSD: deviation rules, checkpoints
                                                        Loom: hook-enforced, auto-retry
verify-work                 wave-gate                   GSD: goal-backward (4 levels)
                                                        Loom: tests + review + spec
complete-milestone          /loom --complete            GSD: archive + tag
                                                        Loom: cleanup + PR
```

#### Enforcement Model

**GSD**: All enforcement via prompt instructions. Agents are told "you MUST do X" but nothing physically prevents violations. Relies on LLM compliance.

**Loom**: Hook-enforced via TypeScript handlers. State file has chmod 444 OS protection. PreToolUse hooks block Edit/Write/MultiEdit calls. Phase ordering physically enforced — agents can't skip phases even if they "want" to.

**Implication**: GSD's patterns can be adopted at the **prompt level** (templates) or **promoted to hook enforcement** for critical guarantees.

#### State Management

**GSD**: Markdown-based (STATE.md, 100 lines max). Parsed with regex/frontmatter. Human-readable but fragile. Uses `gsd-tools.js` CLI (~50 atomic commands) for CRUD operations.

**Loom**: JSON state machine with typed fields. `StateManager` class with atomic writes and file locking. Machine-readable, hook-writable only. More robust but less human-inspectable.

**Insight**: GSD's 100-line STATE.md constraint is smart context engineering — forces compression. Our JSON state can grow unbounded. Consider adding a max-size check.

### Stealable Patterns — Detailed

#### Pattern 1: Discussion/Gray-Area Phase (HIGH VALUE)

**What GSD does**: Before planning, `discuss-phase` identifies **gray areas** — specific decisions that could go multiple ways. Not generic ("how should UI look?") but concrete ("Cards vs list view? Duplicate handling strategy? Folder naming convention?").

For each selected area:
1. Announce topic clearly
2. Ask 4 focused questions with concrete options
3. Check satisfaction
4. Repeat if needed

Output: `CONTEXT.md` with three buckets:
- **User decisions** (locked — downstream agents honor exactly)
- **Claude's Discretion** (flexibility exists)
- **Deferred ideas** (noted for future phases)

**Why loom needs this**: The 2026-02-06 loom review identified brainstorm→specify as the weakest handoff. Free-form brainstorm text doesn't translate cleanly to structured spec requirements. A discuss phase bridges this gap by forcing concrete decisions before specification.

**Scope protection**: When users suggest out-of-scope features during discussion, GSD redirects without dismissing: "[Feature] sounds like a new capability — that belongs in its own phase. I'll note it as a deferred idea."

**Implementation options**:
1. New `discuss-agent` between brainstorm and specify
2. Enhance `clarify-agent` to run pre-specify (currently only post-specify)
3. Add discussion prompts to `phase-specify.md` template (lightest touch)

**New state fields**:
```json
{
  "phase_artifacts": {
    "brainstorm": "completed",
    "discuss": ".claude/specs/{slug}/decisions.md",
    "specify": null
  }
}
```

#### Pattern 2: Plan Validation Agent (HIGH VALUE)

**What GSD does**: `gsd-plan-checker` runs before execution and validates 7 dimensions:

1. **Requirement coverage** — every phase requirement has corresponding tasks
2. **Task completeness** — all required fields present (files, action, verify, done)
3. **Dependency correctness** — valid acyclic graphs, no cycles
4. **Key links planned** — artifacts wired together, not isolated
5. **Scope sanity** — fits context budget (2-3 tasks/plan optimal)
6. **Verification derivation** — must_haves reflect user-observable outcomes
7. **Context compliance** — honors locked decisions from CONTEXT.md

Returns PASSED or ISSUES FOUND with blocker/warning/info levels.

**Why loom needs this**: `validate-task-graph` only checks JSON schema (correct types, required fields). It doesn't check whether the plan will achieve the spec requirements. A task graph can be schema-valid but produce zero useful code.

**Implementation options**:
1. New `validate-plan-agent` spawned between decompose and execute
2. Enhanced `validate-task-graph` helper with spec-coverage check
3. Add validation prompts to decompose-agent output requirements

**Key checks to add**:
- Every spec anchor (FR-xxx) mapped to at least one task
- No dependency cycles in wave graph
- File ownership doesn't overlap between parallel tasks
- Task descriptions are specific (not "add authentication" but "create POST /api/auth/login")

#### Pattern 3: Goal-Backward Verification (HIGH VALUE)

**What GSD does**: The `gsd-verifier` doesn't ask "did tasks complete?" — it asks "does the codebase deliver promised functionality?" through 4 levels:

```
Level 1: EXISTS       — File at expected path?
Level 2: SUBSTANTIVE  — Real code, not stubs? (anti-stub detection)
Level 3: WIRED        — Imported and used in the system?
Level 4: FUNCTIONAL   — Actually works when invoked?
```

**Anti-stub detection patterns**:
- Comment-based: TODO, FIXME, "coming soon", ellipsis
- Placeholder text: "lorem ipsum", "under construction", template brackets
- Trivial implementations: return null/undefined/empty, only console.log
- Hardcoded values: static IDs, counts where dynamic expected

**Wiring verification**:
- Component → API: fetch/axios calls exist, responses consumed
- API → Database: queries execute with await, results in response
- Form → Handler: submit handlers invoke actual mutations
- State → Render: JSX uses state variables dynamically

**Why loom needs this**: Wave gate checks tests + review + spec-alignment, but:
- A test can pass with trivial implementation
- A review can miss stubs if reviewer is superficial
- Spec-check validates coverage, not substance

**Implementation options**:
1. 6th wave gate check: `substance_verified`
2. Enhance spec-check agent to include substance checks
3. Separate `verify-substance` helper in wave-gate flow

#### Pattern 4: Executor Deviation Rules (HIGH VALUE)

**What GSD does**: 4-rule framework for executor autonomy:

| Rule | Trigger | Action |
|------|---------|--------|
| 1 | Code doesn't work as intended | Auto-fix bugs inline |
| 2 | Missing essential for correctness/security | Auto-add critical functionality |
| 3 | Blocking issue (dependency, import, env var) | Auto-fix |
| 4 | Structural modification required | **STOP → checkpoint with proposal** |

Rules 1-3 require no permission. Rule 4 demands explicit decision before proceeding.

All deviations logged in SUMMARY.md with rule category and fix details.

**Why loom needs this**: Impl agents have no structured protocol for unexpected situations. They either succeed or fail — binary outcome. No graduated autonomy, no deviation logging.

**Implementation**:
- Add deviation rules to `impl-agent-context.md` template (prompt-level, no hooks needed)
- Add `deviations` field to task state (populated by update-task-status from transcript)
- Optional: hook that detects Rule 4 escalation and pauses execution

#### Pattern 5: Quick Mode (MEDIUM VALUE)

**What GSD does**: `/gsd:quick` for ad-hoc tasks:
- Single plan, 1-3 tasks max
- ~30% context budget
- Skips research, plan checking, verification
- Separate tracking in `.planning/quick/`
- Tracked in STATE.md but doesn't block planned work

**Why loom needs this**: Currently all-or-nothing. A simple "add logout button" goes through brainstorm→specify→clarify→arch→decompose→execute. With --skip flags it's still clunky. Quick mode would:
- Skip all pre-execute phases
- Create single-wave plan inline (no decompose agent)
- Relaxed wave gate (no spec-check, optional review)
- No GitHub issue

**Implementation**: `/loom --quick "description"` flag. Bypass hook enforcement by not creating state file, or create minimal state with `quick_mode: true` that relaxes hook checks.

#### Pattern 6: Checkpoint Protocol (MEDIUM VALUE)

**What GSD does**: 3 checkpoint types during execution:

| Type | Frequency | Purpose |
|------|-----------|---------|
| `human-verify` | 90% | Confirm visual/functional correctness |
| `decision` | 9% | Choose between implementation options |
| `human-action` | 1% | Unavoidable manual step (OAuth, email verify) |

Executor pauses, presents structured state (completed tasks, current position), waits for user response, then resumes with fresh agent and explicit continuation state.

**Why loom needs this**: During execute phase, loom is fully autonomous. No mid-wave pause mechanism. If an agent encounters an auth gate or needs a design decision, it either fails or makes assumptions.

**Implementation**:
- Add `checkpoint_type` field to task state
- Detect checkpoint signals in SubagentStop transcript parsing
- Pause wave execution, present to user
- Resume with continuation context

#### Pattern 7: Performance Metrics (MEDIUM VALUE)

**What GSD does**: Tracks per-plan execution duration, completion counts, trend analysis (improving/stable/degrading). Stored in STATE.md performance section.

**Why useful**: Enables velocity tracking, bottleneck identification, and evidence-based model allocation. "Architecture agents take 3x longer than impl agents" → move arch to opus, impl to sonnet.

**Implementation**: Add `started_at`/`completed_at` timestamps to task state. Calculate durations in wave-gate or complete hooks. Store aggregate metrics.

#### Pattern 8: Atomic Commit Enforcement (MEDIUM VALUE)

**What GSD does**: Each task gets independent commit:
- Stage only task-related files (never `git add .`)
- Format: `{type}({phase}-{plan}): {description}`
- Record commit hash in SUMMARY.md
- Enables git bisect and independent revert

**Why loom needs this**: Already have `start_sha` stored by `validate-task-execution.sh`. Could verify a commit exists between `start_sha` and current HEAD in `update-task-status.sh`. Currently no enforcement — agents may or may not commit.

**Implementation**: In `update-task-status.ts`, check `git log start_sha..HEAD --oneline | wc -l`. If 0, set `committed: false` warning. Don't block — some agents legitimately don't commit (test-only tasks).

#### Pattern 9: Model Profiles (LOW VALUE)

**What GSD does**: Maps agent types to model tiers based on profile:

```
quality:   planner=opus,  executor=opus,   verifier=sonnet
balanced:  planner=opus,  executor=sonnet, verifier=sonnet
budget:    planner=sonnet, executor=sonnet, verifier=haiku
```

**Implementation**: Add `model` field to Task tool spawning in loom templates. Map from agent type. Already partially handled by Claude Code's model parameter.

#### Pattern 10: Session Continuity (LOW VALUE)

**What GSD does**: STATE.md captures last session timestamp, final action, and pointer to `.continue-here` resume file. Structured `/clear` guidance explains context window management.

**Why partially covered**: Loom's `cleanup-stale-subagents.sh` handles stale tracking files. State file persists across sessions. But no structured "here's exactly where you left off" format.

### Patterns NOT Worth Adopting

#### Parallel Research Agents (4 agents at init)

GSD spawns 4 researchers (stack, features, architecture, pitfalls) in parallel. Loom's brainstorm is a single agent. While impressive, this is:
- Expensive (4× opus/sonnet calls)
- Designed for greenfield projects (Loom is feature-level, not project-level)
- Brainstorm + specify already covers feature-level research adequately

**Verdict**: Skip. Different scope.

#### Markdown-Based State

GSD uses STATE.md (100-line cap) parsed with regex. Our JSON + StateManager is more robust, machine-readable, and hook-writable. Would be a regression.

**Verdict**: Skip. JSON state is strictly better for hook-based systems.

#### gsd-tools.js CLI (~50 commands)

GSD has a monolithic CLI for all state operations. Our `cli.ts` with handler routing + StateManager is more modular and type-safe.

**Verdict**: Skip. Our architecture is cleaner.

#### Brownfield Mode (map-codebase)

GSD's `/gsd:map-codebase` spawns agents to analyze existing code. Loom agents already explore codebases naturally via the Explore subagent type. Not needed as a formal phase.

**Verdict**: Skip. Already covered implicitly.

### Integration with Existing Loom Enhancements

These GSD patterns complement the clnode patterns already planned:

```
clnode patterns              GSD patterns
───────────────              ────────────
work_summary (SubagentStop)  ← feeds → Goal-backward verification (substance check)
context injection (Start)    ← feeds → Deviation awareness (prior agent decisions)
compression (Haiku)          ← feeds → Performance metrics (context budget tracking)
```

**Combined data flow**:
```
Discussion phase → decisions.md (GSD)
  → Spec with locked decisions
    → Plan validated pre-execute (GSD)
      → Agent spawns with injected context (clnode)
        → Agent follows deviation rules (GSD)
          → SubagentStop: compress summary (clnode) + extract deviations (GSD)
            → Wave gate: tests + review + spec + substance check (GSD)
              → Metrics recorded (GSD)
```

### Adoption Roadmap

#### Phase 1: Quick Wins (prompt-level, no new hooks)

1. **Quick mode** — `/loom --quick` flag, bypass pre-execute phases
2. **Deviation rules** — Add rules 1-4 to `impl-agent-context.md` template
3. **Atomic commit check** — Warning in `update-task-status.ts` if no commit found
4. **Task specificity requirement** — Add to decompose template: "reject vague tasks"

#### Phase 2: High Impact (new hooks/agents)

5. **Discussion phase** — New phase between brainstorm and specify (or enhanced clarify)
6. **Plan validation** — New hook or agent between decompose and execute
7. **Goal-backward verification** — Substance checks in wave gate
8. **Deviation logging** — New `deviations` field in task state, parsed from transcript

#### Phase 3: Polish

9. **Checkpoint protocol** — Mid-execution pause/resume mechanism
10. **Performance metrics** — Duration tracking per task/wave
11. **Model profiles** — Agent-to-model mapping with quality/balanced/budget profiles
12. **Compressed summaries** — (Already planned from clnode analysis)

### Cost Analysis

| Pattern | Implementation Cost | Ongoing Cost | Value |
|---------|-------------------|--------------|-------|
| Discussion phase | New agent/template | ~$0.50/run | HIGH |
| Plan validation | New agent or enhanced helper | ~$0.30/run | HIGH |
| Goal-backward verification | Enhanced wave gate | ~$0.20/run | HIGH |
| Deviation rules | Template change only | $0 | HIGH |
| Quick mode | Flag + skip logic | $0 | MEDIUM |
| Checkpoints | New hook handler | $0 | MEDIUM |
| Metrics | Field additions | $0 | MEDIUM |
| Commit enforcement | Enhanced hook | $0 | MEDIUM |

## Unresolved Questions

- Discussion phase: new agent or enhance existing clarify-agent?
- Quick mode: same hooks active (relaxed) or bypass entirely (no state file)?
- Plan validation: separate agent or enhanced validate-task-graph helper?
- Goal-backward verification: new wave gate check or extend spec-check agent?
- Deviation rules: prompt-only or enforce via hooks (new SubagentStop handler)?
- Substance checks: how to detect stubs without high false-positive rate?
- Checkpoint resume: fresh agent with state or same agent continuation?
- Discussion + clarify overlap: merge into single "resolve ambiguity" phase?
