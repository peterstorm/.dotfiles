# MCP Server Design / Review Report

## Server Overview

- **Name:** [server-name]
- **Purpose:** [one sentence describing the server's single job]
- **Target workflows:** [3-5 agent stories this server enables]
- **Transport:** [stdio (local) / Streamable HTTP (remote)]
- **Auth method:** [OAuth 2.1 / Token / Env vars / None]

---

## Tool Inventory

| # | Tool Name | Description | Risk Level | Required Args | Optional Args |
|---|-----------|-------------|------------|---------------|---------------|
| 1 | `tool_name` | Complete outcome description | read-only | `email: str` | `limit: int = 10` |
| 2 | ... | ... | write | ... | ... |

**Total tools:** [N]
**Token budget estimate:** 200K / [N] = ~[X]K tokens per tool

---

## Per-Tool API Design

### `tool_name`

```
Purpose: [what agent achieves with this tool]

Arguments:
  email: str          -- user's email address (required)
  format: Literal["basic", "detailed"] = "basic"  -- output detail level
  limit: int = 10     -- max results to return

Returns: [description of return format and content]

Example:
  tool_name("alice@co.com", format="detailed", limit=5)

Error scenarios:
  - User not found -> "No user found for 'alice@co.com'. Verify the email."
  - Too many results -> "Found 1,234 results. Use limit parameter or add filters."
```

---

## Security Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Authentication | [OAuth 2.1 / Token / ...] | [why] |
| Read/write separation | [yes/no] | [how tools are split] |
| Input validation | [schema validation / ...] | [what's validated] |
| Scope model | [progressive / static] | [elevation strategy] |
| Elicitation | [yes/no] | [which destructive operations use human-in-the-loop] |

---

## Transport & Deployment

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Transport | [stdio / Streamable HTTP] | [why] |
| Containerization | [Docker / bare process] | [isolation strategy] |
| Logging | [stderr JSON / MCP logging cap] | [what's logged] |
| Versioning | [semver / ...] | [evolution strategy] |
| Registry | [MCP Registry / Docker Catalog / private] | [distribution plan] |

---

## Reliability

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Idempotency | [idempotency keys / dedup check / n/a] | [strategy for write tools] |
| Pagination | [cursor-based / offset / n/a] | [for list operations] |
| Structured output | [outputSchema / plain text] | [which tools use it] |
| Resource links | [yes / no] | [for large payloads] |

---

## Review Scorecard (Review Mode Only)

| Dimension | Score | Notes |
|-----------|-------|-------|
| Outcome orientation | /5 | |
| Argument design | /5 | |
| Documentation quality | /5 | |
| Token efficiency | /5 | |
| Curation | /5 | |
| Security | /5 | |
| LLM alignment | /5 | |
| Reliability | /5 | |
| Operations | /5 | |
| **Overall** | /45 | |

---

## Findings (Review Mode Only)

### Critical

1. **[Issue title]**
   - Principle violated: [which of the 5 foundational principles]
   - Current: [what the code does now]
   - Fix: [specific, actionable change]

### Warnings

1. **[Issue title]**
   - ...

### Suggestions

1. **[Issue title]**
   - ...

---

## Consolidation Opportunities (Review Mode Only)

| Current Tools | Proposed Consolidation | Rationale |
|---------------|----------------------|-----------|
| `get_X`, `get_Y`, `get_Z` | `get_info(category: Literal["x","y","z"])` | Reduces 3 tools to 1 |

---

## Positive Observations

- [What's done well]
- [Patterns worth keeping]
