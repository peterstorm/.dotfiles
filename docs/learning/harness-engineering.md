# Harness Engineering for AI

*Learned: March 2026*

## What It Is

Harness engineering is the discipline of building the entire system -- constraints, tools, feedback loops, and guardrails -- around AI agents so their raw power produces reliable output at scale.

The term was coined by Mitchell Hashimoto (creator of Terraform, co-founder of HashiCorp) in February 2026. OpenAI and Thoughtworks then expanded on the concept.

## The Evolution Stack

Each layer is a strict superset of the one below it:

| Layer | Question It Answers |
|---|---|
| Prompt Engineering | "How should I phrase this instruction?" |
| Context Engineering | "What does the model need to know?" |
| Harness Engineering | "How do agents operate reliably across thousands of inferences?" |

Prompts nudge behavior probabilistically. The harness enforces behavior deterministically. You cannot prompt your way to 99.9% reliability.

## Three Pillars

### 1. Context Engineering

The knowledge layer: everything the agent can access beyond the prompt.

- Structured `docs/` directories, `AGENTS.md` files
- Dynamic context: logs, metrics, traces, browser access
- Progressive disclosure: small stable entry point, agent discovers more as needed

### 2. Architectural Constraints

Deterministic guardrails enforced by code, not by asking nicely.

Two types:
- **Active constraints** (before the agent writes code): templates, directory conventions, tool interfaces that only accept valid inputs. These make the correct path the easiest path.
- **Passive constraints** (after the agent writes code): linters, type checkers, structural tests, CI pipelines. These reject bad output and feed error messages back into the agent's context.

The ideal balance: active constraints handle the 80% case (predictable structure), passive constraints catch the 20% (unexpected deviations).

**Key technique -- error messages as context injection:**

A lint error for a human says "fix this." A lint error for an agent becomes part of its context window for the next inference. A well-crafted error message should include:
1. What rule was violated
2. How to fix it (concrete steps)
3. Where to learn more (pointer to docs)

Bad: `Module boundary violation in auth/service.ts`

Good: `Module boundary violation in auth/service.ts. auth/ modules must NOT import from billing/. Define an interface in shared/ports/ and inject it. See docs/architecture/module-boundaries.md.`

### 3. Entropy Management

Over time, agents accumulate drift: inconsistent naming, diverging patterns, stale documentation. This matters because the codebase IS the context for future agent runs. Degraded codebase = degraded context = degraded agent performance.

Entropy is an emergent property of many individually-correct changes. Pillars 1 and 2 check individual changes. Pillar 3 checks the population. No single PR violates a rule, but 50 PRs each making slightly different naming choices produce inconsistency that no per-file lint rule catches.

**What drifts:**

| Drift type | Example | Why constraints miss it |
|---|---|---|
| Naming drift | `getUserById` vs `fetchUser` vs `loadUserRecord` | No linter enforces consistency *across* files |
| Documentation drift | Code changes, docs don't update | Tests verify behavior, not doc accuracy |
| Pattern drift | Early modules use pattern A, later modules use B | Structural tests check rules, not consistency |
| Dependency creep | Each service adds "just one more" import | Under-threshold individually, problematic in aggregate |
| Dead code | Agents add code but rarely remove old code | Nothing flags working-but-unused code |

**Three mechanisms:**

1. **Detection** -- Periodic scans that query the codebase in aggregate. Not "is this file correct?" but "how many different naming patterns exist for fetch functions?" Run on a schedule (daily/weekly), not per-PR. Entropy is slow; per-PR scanning adds latency for marginal benefit.

2. **Grading** -- Score quality per domain as a percentage of compliance with golden principles, tracked over time. A single score means little. A declining trend (93 -> 91 -> 88 over three weeks) signals a missing constraint. Thresholds: 95-100% healthy, 85-94% watch, below 85% act.

3. **Repair** -- Automated fix-up PRs for mechanical issues (rename, delete dead code, update doc references). Escalation for judgment calls (architectural divergence).

**The meta-loop:** Entropy management's most valuable output is not the fix-up PR -- it's the signal that a constraint is missing. If the same drift category recurs weekly, promote it to a Pillar 2 lint rule so it's caught per-PR instead of periodically. Hashimoto's principle applied one level up: every *harness* failure improves the harness.

## The Closed-Loop Mechanism

Hashimoto's core principle:

> Anytime you find an agent makes a mistake, you take the time to engineer a solution such that the agent never makes that mistake again.

This works because:
1. **Finite failure classes** -- for any bounded domain, there are a limited number of ways agents go wrong.
2. **Permanent fixes** -- each fix is structural (code/config), so it persists across sessions, models, and agents.
3. **Monotonic improvement** -- fixes only accumulate, they don't regress (assuming entropy management keeps the harness clean).

Each failure welds shut one hole. The failure rate drops asymptotically over time.

## Designing for the Retry Loop

Assume the agent will fail on the first attempt. Design constraints so the second attempt succeeds.

- **Fast feedback** -- linters and type checks in seconds, not minutes
- **Specific errors** -- actionable, not just "build failed"
- **One error at a time** -- a wall of 50 errors overwhelms the context window
- **Deterministic ordering** -- same input produces same errors; flaky tests corrupt the feedback signal

Flaky tests are especially dangerous for agents. A test that passes 90% of the time teaches the agent that failures are sometimes ignorable, blurring the line between real errors and noise.

## Production Agent Orchestration

Four patterns for running agent fleets at scale.

### Isolated Environments

Each agent gets its own full environment: git worktree, app instance, observability stack (logs, metrics, traces), and browser session. Torn down when the task completes.

Separate git branches solve code-level conflicts. Full environments solve the runtime problem: Agent A's database writes don't corrupt Agent B's test data, Agent A's logs don't appear in Agent B's context. Isolation enables parallel execution and safe failure -- an agent can break its environment without blocking anyone.

### Agent-to-Agent Review

The authoring agent opens a PR. A separate reviewer agent (fresh context, separate run) reviews the diff. The author responds to feedback. This loops until the reviewer is satisfied. Humans may review but aren't required to.

The reviewer's advantage is fresh context. The authoring agent has hours of implementation residue in its context window. The reviewer starts clean and catches things the author missed -- the same reason human code review works, but it scales infinitely.

### Context Firewalls (Parent-Child Architecture)

Agents degrade as their context fills with file reads, grep results, and tool outputs. After enough accumulation, even simple tasks fail (the "idiot zone").

Solution: a parent agent handles planning and orchestration (expensive model, clean context). Child agents execute narrow tasks in isolated context windows (cheap models). Children return only compressed results and source references. Their working context never pollutes the parent. The parent stays in the "smart zone" across dozens of sub-tasks.

### Silent-Success Feedback Loops

Success should be silent; only failure should make noise. 4,000 passing tests produce zero output -- zero tokens injected into context. 3 failing tests produce only those 3 failure messages. Every token of "all good" displaces a token the agent needs for its actual task.

Additional middleware patterns:
- **PreCompletionChecklist** -- intercepts the agent before submission, forces validation against task specs
- **LoopDetection** -- tracks repeated edits to the same file; after N repetitions, injects "consider a different approach"

LangChain went from top 30 to top 5 on Terminal Bench 2.0 with these harness changes alone. Same model, different harness.

### Execution Plans as Artifacts

Plans are versioned, checked into the repo under `docs/exec-plans/`. Each plan includes the goal, acceptance criteria, progress log, decision log, and known issues. Agents are stateless between runs -- the plan file gives the next run full context on where things stand, avoiding re-exploration of dead ends.

### Escalation and Autonomy Gradients

Stripe's two-strike rule: if an agent's first CI fix fails, escalate to humans immediately. An agent given many retries on a hard problem will eventually "solve" it by working around the issue -- producing code that passes CI but doesn't address the root cause.

Autonomy increases as the harness tightens. More constraints = safer to grant more freedom. Sturdy guardrails allow a higher speed limit because mistakes are contained. OpenAI's trajectory: early on, humans reviewed every PR. As they added linters, structural tests, agent reviewers, and observability, they could safely let agents merge their own code.

## Production Validation

**OpenAI Codex team:** ~1M lines of production code, ~1,500 PRs, zero human-written code over 5 months. 3 engineers (later 7), 3.5 PRs per engineer per day. Agents reproduce bugs, record video, implement fixes, validate, open PRs, respond to review feedback, and merge. Single runs working 6+ hours.

**Stripe "Minions":** 1,300+ PRs per week merged without human oversight.

## Practical Application: Loom Plugin as a Harness

The Loom plugin (`~/dev/claude-plugins/loom/`) is a harness implementation. Here's how it maps to the three pillars.

### Pillar 1 (Context Engineering) -- Strong

- **43+ skills as demand-loaded context.** Skills load when triggered, delivering domain-specific instructions at the point of need. "Give a map, not a manual."
- **Phase prompt templates** (`loom/commands/templates/`) and reference files (`loom/references/`) give agents structure to fill in, not invent.
- **CLAUDE.md as table of contents.** ~65 lines pointing to deeper sources. Matches OpenAI's pattern.
- **Cortex plugin** extracts semantic memory from sessions via Gemini, injected into future sessions as `cortex-memory.local.md`. Persistent agent memory across sessions -- goes beyond what OpenAI describes publicly.
- **Domain-specific configs** (`claude/project/{java,typescript,rust,marketing}/`) with per-domain skills, agents, and rules. Symlink-based activation per project.

### Pillar 2 (Architectural Constraints) -- Very Strong

Loom's constraints are programmatic, not documented. Key handlers:

- **`block-direct-edits`**: Orchestrator cannot use Edit/Write/MultiEdit. All changes through subagents via Task tool. Hard wall enforcing separation of concerns.
- **`validate-phase-order`**: Enforces 8-phase pipeline (init -> brainstorm -> specify -> clarify -> architecture -> plan-alignment -> decompose -> execute). Each phase requires artifacts from previous phases (spec.md before architecture, plan.md before decompose). Uses `ts-pattern` for exhaustive matching.
- **`guard-state-file`**: Task graph protected by chmod 444 at rest. Only whitelisted helper scripts can write. Prevents "agent modifies its own instructions."
- **`validate-template-substitution`**: Blocks unsubstituted `{variable}` patterns. Catches template pass-through failures.
- **`validate-task-execution`**: Enforces wave ordering. Can't jump to wave 3 while wave 1 is incomplete.
- **Wave gate** (`complete-wave-gate.ts`): 5 checks before advancing -- test evidence, new tests written, spec alignment, reviews complete, no critical findings. Quality gate enforced in code.
- **Agent-targeted error messages**: Every block includes what went wrong, what to do instead, and which agents to use.

### Pillar 3 (Entropy Management) -- Gap

No periodic scanning, quality grading, or drift detection. Opportunities:

1. **Skill consistency scanner** -- audit 43+ skills for naming drift, format inconsistency, stale path references
2. **Documentation freshness** -- check whether file paths mentioned in skill files still exist
3. **Cross-platform drift** -- Loom (Claude Code) and opencode-task-planner (OpenCode) should stay aligned; a diff-based detector could flag divergence
4. **Quality grading** -- wave gate is pass/fail; adding continuous quality scores per domain tracked over time would surface slow degradation

### Other Improvement Opportunities

- **Silent-success feedback**: Wave gate outputs verbose success messages for each check. Passing checks could compress to a single line, preserving context.
- **Loop detection**: No middleware to detect if an agent is stuck editing the same file repeatedly. A loop detector injecting "consider a different approach" after N repetitions would prevent workaround spirals.

### What's Unique

Two patterns not seen in OpenAI/Stripe public descriptions:

1. **Cortex (persistent semantic memory)** -- richer than stateless execution plans
2. **Phase enforcement with artifact gates** -- programmatic verification that spec.md exists, counting NEEDS CLARIFICATION markers to trigger clarify phase, checking plan-alignment.md before decompose. More rigorous than publicly documented systems.

## Sources

- [Mitchell Hashimoto -- "My AI Adoption Journey"](https://mitchellh.com/writing/my-ai-adoption-journey#step-5-engineer-the-harness) (Feb 5, 2026)
- [OpenAI -- "Harness Engineering"](https://openai.com/index/harness-engineering/) (Feb 11, 2026)
- [Birgitta Boeckeler on Martin Fowler's site](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering.html) (Feb 17, 2026)
- [harness-engineering.ai](https://harness-engineering.ai/blog/what-is-harness-engineering/)
- [HumanLayer -- "Skill Issue: Harness Engineering for Coding Agents"](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents)
- [LangChain -- "Improving Deep Agents"](https://blog.langchain.com/improving-deep-agents-with-harness-engineering/)
- [Alibaba Cloud -- "4 Real Cases"](https://www.alibabacloud.com/blog/4-real-cases-%7C-harness-engineering-is-becoming-the-new-moat_602970)
