---
source: https://youtu.be/jsI18Htgf8k
date: 2026-02-09
speaker: Unknown (indie dev / YouTuber, runs production messaging app for sales agents)
type: idea-analysis
verdict: Steal one piece
viability: green
hype-risk: yellow
business-fit: green
segment-fit: A
tags: [idea-analysis, developer-workflow, claude-code, automation, linear, sub-agents]
---

# Claude Code + Linear: Automated Issue Resolution Workflow

## TL;DR

Workflow combining Claude Code slash commands with Linear (project management) to automate the full issue-resolution lifecycle — from fetching an issue to planning via TDD, implementing, opening a PR, running code review, fixing review issues, and updating Linear — all with a single slash command. Only manual step: initial planning/decision-making.

## Scores

- **Idea Viability** 🟢 **Strong** — Real productivity workflow with demonstrated results; not a product to sell but a process to adopt.
- **Hype/BS** 🟡 **Medium risk** — Practitioner with real product, but newsletter funnel + cherry-picked demo + "hours saved" framing need scrutiny.
- **dotslash.dev Fit** 🟢 **Strong (Segment A)** — Directly applicable to own dev workflow AND packageable as consulting IP for tech teams.
- **Effort vs Payoff** 🟢 **High payoff** — Already have 80% of this built; marginal effort to formalize the remaining pieces.

**One-liner: "You're already doing this. Steal the Linear MCP integration and the iterative review loop pattern — skip the newsletter."**

## The Workflow (Detailed)

### Process Diagram

```
Plan (human, 5-10 min)
  → Fetch issue via MCP
  → Create branch (auto-linked to Linear via naming convention)
  → Spin up plan agent (TDD — tests first)
  → Spin up implementation agent
  → Commit / push / open PR
  → Monitor PR checks (background task)
  → PR review (sub-agent)
  → Fix review issues (sub-agent)
  → Re-review until approved
  → Update Linear issue with findings
  → Human reviews final PR and merges
```

### Key Design Decisions

1. **Sub-agents for everything after planning** — keeps main context window small. Demo used ~73K tokens over 26 minutes with plenty of context left.
2. **TDD-first in the plan agent** — writes tests before implementation, ensuring coverage before review catches remaining issues.
3. **Branch naming convention** — includes Linear issue ID, auto-links and moves issues through statuses (backlog → in progress → in review).
4. **Iterative review loop** — review agent flags issues → fix agent addresses them → re-review validates → repeat until approved.
5. **Background CI monitoring** — agent watches for GitHub Actions check failures and auto-fixes.

### Linear Organization

- **Issues** = atomic unit of work, narrow enough for one context window
- **Projects** = groups of related issues (e.g., "implement payments" = Stripe + DB + pricing page + checkout)
- **Milestones** = optional grouping within projects
- **Blocking** = Linear natively supports issue dependencies; Claude uses this for execution ordering

### Slash Commands Mentioned

1. **Create Linear issue** — template-based, walks through refinement until well-defined with no ambiguity. Includes: summary, current vs expected behavior, acceptance criteria, scope, root cause analysis.
2. **Create Linear project** — 6-step workflow, creates individual issues via the issue slash command, sets up blocking relationships.
3. **Resolve issue** — the main automation. Single command that executes the full pipeline above.
4. **Enhance issue** — for issues created from other sources (e.g., Sentry), normalizes them to the standard template.

## Viability Analysis

### Why it works

- Solves real pain point every developer using AI coding tools faces (babysitting through repetitive steps)
- The steps after planning ARE deterministic and repeatable — good automation target
- Sub-agent pattern for context preservation is genuinely clever and matches Anthropic's own recommendations
- Demo is verifiable — real feature (read receipts) deployed to real production app
- Linear's blocking/dependency system provides real structural advantage over ad-hoc task management
- 26-min / 73K-token result is concrete and plausible for a well-scoped issue

### Limitations not discussed

- No mention of failure rate — how often does the full pipeline actually produce a shippable PR?
- Race condition caught in review is presented as "the system works" but also reveals AI-generated code quality concerns
- Context window management with sub-agents means each sub-agent starts with limited context about the broader system
- Works best for well-scoped, isolated issues — complex cross-cutting changes would likely fail
- TDD-first sounds good but AI-generated tests often test the implementation rather than the behavior

## Hype/BS Detailed Assessment

### Green Flags ✅

- **Practitioner** — has actual production messaging app, not just teaching
- **Shows real code** — real GitHub activity, real deployment, real PR with real review comments
- **Intellectually honest about planning** — "no one knows your domain better than you, including any AI"
- **Shows warts** — race condition caught in review, 5 issues found, doesn't pretend it's flawless
- **Concrete numbers** — 26 minutes, 73K tokens, 5 review issues

### Red Flags 🚩

- **Newsletter funnel** — free Substack "The AI Launchpad" with prompts as the hook. Classic content-to-newsletter pipeline.
- **Cherry-picked demo** — showed ONE successful run. No mention of failure rate, hallucinations, context window blowups, or issues the review loop didn't catch.
- **"Saving me hours every day"** — vague time savings without baseline. How many issues/day? What's actual error rate?
- **GitHub contribution graph as proof** — correlation ≠ causation. More commits ≠ better software.
- **"Next step: REPL loops / multi-bot"** — teases autonomous coding without acknowledging massive reliability gap between supervised and unsupervised loops.
- **"Anyone can do this" implied** — prompts shared on newsletter, but the effectiveness depends heavily on codebase quality, test infrastructure, CI setup, and well-written issues.

### Verdict

Genuine practitioner with real insights, but packaging it for content/newsletter growth. The workflow is real; the implied ease is exaggerated.

## dotslash.dev Fit Analysis

### Segment A (AI Consulting) — 🟢 Strong

- Directly relevant to consulting offering: "here's how we set up automated dev workflows for your team" is a tangible deliverable
- Already have slash commands (`/finalize`, `/review-pr`), sub-agent patterns, and TDD discipline — just need to formalize the end-to-end chain
- Packageable as "developer productivity audit" or "AI workflow setup" engagement for tech teams
- Linear MCP integration is the one missing piece — worth exploring for consulting clients using Linear
- Demonstrates production AI expertise (one of the consulting differentiators)

### Segment B (SMB Product) — 🔴 Irrelevant

- Copenhagen plumbers don't need automated PR review loops
- Pure developer tooling, no SMB application

## Effort vs Payoff

### Already have (80%)

- ✅ Slash commands for commit, PR, review (`/finalize`)
- ✅ Sub-agent patterns (documented in CLAUDE.md)
- ✅ TDD discipline (jqwik property tests, test-first architecture)
- ✅ PR review automation (`/review-pr`)
- ✅ Atlassian MCP tools in skill list (`atlassian:triage-issue`, etc.)

### Would need to add (20%)

- Linear/Jira MCP integration for issue fetching + status updates
- Single "resolve issue" slash command chaining existing commands
- Background task monitoring for CI checks
- Branch naming convention automation tied to issue IDs

### Estimated effort

~1 day to formalize into a `/resolve-issue` skill that chains existing components. ROI is in own shipping velocity + consulting IP.

## What to Steal

1. **The "resolve issue" orchestrator pattern** — one slash command chaining: fetch issue → branch → plan → implement → commit → PR → review → fix → re-review. Have all pieces; chain them.
2. **Linear/Jira MCP for status automation** — branch naming conventions that auto-move issues through statuses.
3. **Background CI monitoring** — agent watches for check failures and auto-fixes as addition to `/finalize` flow.
4. **Issue template discipline** — issues written to be agent-resolvable without clarification. Acceptance criteria, scope boundaries, root cause analysis baked in.

## What to Ignore

- The newsletter and prompt sharing — own prompts are already more sophisticated (architecture rules, property testing, Either/Validation library are deeper)
- "REPL loops / multi-bot" teaser — vaporware until proven. Unsupervised agent loops have terrible reliability at scale.
- GitHub contribution graph flexing
- The specific Linear choice — same pattern works with Jira, GitHub Issues, or any issue tracker with MCP/API access

## Actionable Next Steps

1. Build a `/resolve-issue` skill that calls `/finalize` as its final step
2. Integrate Atlassian MCP (already available) for issue fetching and status updates
3. Add iterative review loop to the pipeline (review → fix → re-review until clean)
4. Package the full workflow as a consulting deliverable: "AI-automated dev pipeline setup"
