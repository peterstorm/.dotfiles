---
name: mcp-expert
description: >
  This skill should be used when the user asks to "design an MCP server",
  "review my MCP server", "MCP best practices", "MCP tool design",
  "design MCP tools", "MCP security review", "consolidate MCP tools",
  "reduce MCP tool count", "audit MCP server", "MCP resources vs tools",
  or mentions designing tools for AI agents following
  Model Context Protocol patterns.
version: 0.1.0
---

# MCP Server Design & Review

Guide the user through designing new MCP servers or reviewing existing ones against established best practices. All guidance is language-agnostic but applies principles from the official MCP specification, Block Engineering's production playbook (60+ servers), and FastMCP creator insights.

## Core Philosophy

> "You are not building a tool. You are building a user interface."
> -- Jeremiah Lowin

Agents are not humans. Three critical differences drive every design decision:

| Dimension | Humans | AI Agents |
|-----------|--------|-----------|
| **Discovery** | Cheap (read docs once) | Expensive (enumerates ALL tools, consumes tokens) |
| **Iteration** | Fast (write script, run repeatedly) | Slow (each call sends entire history) |
| **Context** | Rich (memories, experiences) | Limited (~200K tokens is the entire "brain") |

**The key verb: CURATE.** Every design decision filters through token budget consciousness.

## Mode Selection

Determine which mode to operate in based on user intent:

- **Design Mode** -- user wants to build a new MCP server or redesign an existing one
- **Review Mode** -- user wants to audit/improve an existing MCP server

## MCP Primitives: Choose the Right One

MCP defines four server primitives. Choosing the wrong primitive is a fundamental design error.

| Primitive | Purpose | When to Use |
|-----------|---------|-------------|
| **Tools** | Functions the agent executes (side effects) | Actions: create, update, delete, query with parameters |
| **Resources** | Read-only data the agent or user consumes | Static/semi-static data: schemas, configs, documentation, file contents |
| **Prompts** | Reusable prompt templates for users | Standardized workflows the user triggers (e.g., "summarize this repo") |
| **Sampling** | Server requests LLM completions from client | Server needs AI reasoning mid-operation (agentic loops) |

**Rule of thumb:**
- Read-only data with no side effects → **Resource** (cheaper, subscribable, cacheable)
- Action with side effects → **Tool**
- Reusable user-facing workflow template → **Prompt**
- Server needs to "think" → **Sampling**

Most servers are tool-heavy, but modeling read-only data as Resources instead of Tools reduces tool count, improves token efficiency, and enables client-side caching.

## Design Mode

Follow these steps sequentially. Each step applies one or more foundational principles from `references/design-principles.md`.

### Step 1: Understand the Domain

Ask the user:
- What service/API is being wrapped?
- What are the 3-5 key workflows users (agents) want to accomplish?
- What data flows in and out?
- What data is read-only vs requires mutation?

Focus on **agent stories**, not API endpoints. Frame questions as "What does the agent need to achieve?" not "What endpoints exist?"

### Step 2: Choose Primitives & Design Tool Inventory

First, classify each piece of functionality using the primitives table above. Then apply **Outcomes Not Operations** principle for tools.

- Classify read-only data as **Resources** (schemas, configs, docs) -- reduces tool count
- Map each action workflow to a single **Tool** that delivers a complete outcome
- Name tools for agent intent (e.g., `track_latest_order` not `get_order`)
- Target 5-15 tools total per server
- Apply "One Server = One Job" -- if scope exceeds one clear purpose, split into multiple servers

**Red flags to catch:**
- CRUD-style atomic operations (get/create/update/delete patterns)
- Tools that require chaining to accomplish a single workflow
- REST-to-MCP 1:1 endpoint mirroring

Consult `references/design-principles.md` for detailed guidance on the Outcomes principle and Block's Linear MCP evolution example.

### Step 3: Shape Tool APIs

Apply **Flatten Arguments** principle.

For each tool:
- All arguments as top-level primitives (string, int, bool)
- Use `Literal`/`Enum` for constrained choices -- LLMs handle these well
- Strong defaults to hide complexity -- most args should be optional
- No nested objects, config dicts, or "mystery meat" arguments
- Avoid tightly coupled arguments (where valid values of B depend on A)

### Step 4: Write Documentation as Context

Apply **Instructions Are Context** principle.

- Rich docstrings: purpose, args with descriptions, return format, examples
- Examples are contracts -- LLMs treat them as strong templates
- Actionable error messages that guide recovery, not cryptic failures
- Tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, `title`) for permission systems

### Step 5: Token Budget Check

Apply **Respect Token Budget** principle. Consult `references/llm-alignment.md` for detailed math.

- Estimate total token cost: `200K context / tool_count = tokens per tool`
- Check output sizes -- return summaries + IDs, not raw dumps
- Plan truncation/pagination for large responses
- Consider prompt caching implications (avoid dynamic data in instructions)

Guidelines:
| Tool Count | Status |
|------------|--------|
| 5-15 | Ideal |
| ~50 | Performance degradation begins |
| 100+ | Requires sophisticated routing |

### Step 6: Security Posture

Consult `references/security-checklist.md` for comprehensive guidance.

Key decisions:
- Auth method: OAuth 2.1 (preferred), token-based, or env vars
- Separate read-only vs write/mutate tools (one tool = one risk level)
- Input validation strategy
- Session security (non-deterministic IDs, user binding)
- Scope minimization (progressive, least-privilege)

### Step 7: Output Design Document

Produce a structured design document using `examples/design-review-template.md` as template. Include:
- Server purpose and scope
- Tool inventory table (name, description, risk level)
- Per-tool API shape (args, types, defaults, return format)
- Security decisions
- Token budget estimate

## Review Mode

Follow these steps to audit an existing MCP server. Use `references/review-rubric.md` for detailed scoring criteria.

### Step 1: Discover Scope

- Read the server's tool definitions (scan for decorators, handler registrations, tool schemas)
- Count total tools, categorize read vs write
- Identify the server's declared purpose
- Map tools to workflows they serve

### Step 2: Apply Review Rubric

Score each dimension 1-5 using criteria from `references/review-rubric.md`:

| Dimension | Check |
|-----------|-------|
| Outcome orientation | Each tool = complete workflow? |
| Argument design | Flat primitives with defaults? |
| Documentation quality | Rich docstrings, actionable errors? |
| Token efficiency | Tool count, output sizes controlled? |
| Curation | No redundant tools, focused scope? |
| Security | Auth, read/write separation, validation? |
| LLM alignment | Leverages agent strengths? |

### Step 3: Generate Findings

For each issue found:
- **Severity**: critical / warning / suggestion
- **Principle violated**: which of the 5 foundational principles
- **Current state**: what the code does now
- **Recommended fix**: specific, actionable change with example

### Step 4: Produce Review Report

Output a structured report:
- Summary scorecard (dimension scores)
- Prioritized issue list (critical first)
- Consolidation opportunities (e.g., "these 5 tools could become 2")
- Positive observations (what's done well)

## Additional Resources

### Reference Files

Consult these for detailed guidance:
- **`references/design-principles.md`** -- The 5 foundational principles with examples and anti-patterns
- **`references/security-checklist.md`** -- MCP spec security, OWASP guidance, auth patterns
- **`references/review-rubric.md`** -- Detailed scoring criteria for each review dimension
- **`references/llm-alignment.md`** -- Token budget math, LLM strengths/weaknesses, caching

### Examples

- **`examples/design-review-template.md`** -- Template for design documents and review reports
