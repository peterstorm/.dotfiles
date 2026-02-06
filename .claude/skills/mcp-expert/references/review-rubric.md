# MCP Server Review Rubric

Scoring criteria for each review dimension. Rate 1-5, where 1 = critical issues and 5 = exemplary.

---

## 1. Outcome Orientation

**Question:** Does each tool represent a complete workflow?

| Score | Criteria |
|-------|----------|
| 1 | Pure CRUD/REST mirror. Tools map 1:1 to API endpoints. Agent must chain 4+ calls for a single workflow. |
| 2 | Mostly atomic operations with a few combined tools. Significant chaining still required. |
| 3 | Some tools deliver complete outcomes, but several still expose intermediate operations. |
| 4 | Most tools map to agent workflows. Minimal chaining needed. Few lingering atomic tools. |
| 5 | Every tool = one complete agent story. No unnecessary chaining. Tools named for intent. |

**Red flags:**
- `get_X`, `set_X`, `delete_X` patterns (CRUD)
- Tools that return IDs requiring follow-up calls
- Tool names matching API endpoint paths
- Agent needs 3+ sequential calls for one user request

**Good signs:**
- Tools named for outcomes (e.g., `track_latest_order`, `find_available_meeting_times`)
- Single tool call resolves a complete user intent
- Internal orchestration hidden from agent

---

## 2. Argument Design

**Question:** Are arguments flat, typed, and well-defaulted?

| Score | Criteria |
|-------|----------|
| 1 | Nested config dicts, untyped `dict` or `object` params, no defaults, no constraints. |
| 2 | Some nesting, few defaults. Mix of typed and untyped parameters. |
| 3 | Mostly flat. Some Literal/Enum usage. Reasonable defaults on most optional params. |
| 4 | All top-level primitives. Good use of Literal/Enum. Strong defaults. Minor issues. |
| 5 | Perfectly flat. Every constrained choice uses Literal/Enum. Excellent defaults hide complexity. No tightly coupled args. |

**Red flags:**
- `config: dict`, `options: object`, `params: map`
- Arguments where valid values of B depend on value of A
- More than 6-7 required arguments
- No defaults on optional parameters

**Good signs:**
- `format: Literal["basic", "detailed"]`
- `status: Enum[OPEN, CLOSED, ALL]`
- Most args have sensible defaults
- 2-3 required args, rest optional with defaults

---

## 3. Documentation Quality

**Question:** Are docstrings rich, examples present, and errors actionable?

| Score | Criteria |
|-------|----------|
| 1 | No docstrings or one-liners only. Cryptic error messages. No examples. |
| 2 | Basic docstrings (what it does). Generic errors. No usage examples. |
| 3 | Decent docstrings with arg descriptions. Some actionable errors. No examples. |
| 4 | Rich docstrings with purpose, args, return format. Actionable errors. Missing examples. |
| 5 | Full docstrings with purpose, args, return format, examples, error scenarios. All errors are actionable with recovery instructions. |

**Red flags:**
- `raise ValueError()` or `raise Exception("Error")`
- Docstrings that just repeat the function name
- No arg descriptions
- Errors that say "CRITICAL FAILURE" (agent avoids the tool)

**Good signs:**
- Error messages include recovery instructions
- Examples show realistic usage
- Return format documented
- Annotations present (readOnlyHint, etc.)

---

## 4. Token Efficiency

**Question:** Is the token budget respected?

| Score | Criteria |
|-------|----------|
| 1 | 50+ tools. Returns full DB rows / raw JSON dumps. No size limits. |
| 2 | 30-50 tools. Some large outputs. No truncation strategy. |
| 3 | 15-30 tools. Output sizes somewhat controlled. Basic truncation. |
| 4 | 10-15 tools. Summaries returned. Good truncation/pagination. Caching considered. |
| 5 | 5-10 focused tools. All outputs are summaries + IDs. Progressive disclosure via verbose tools. Prompt caching optimized. |

**Red flags:**
- Tool count exceeding 50
- Tools returning entire database rows
- No file size or output size limits
- Dynamic data in tool instructions (breaks prompt caching)

**Good signs:**
- File size checks before processing
- Truncation with actionable notices
- Separate "verbose" tools for detail on demand
- Static tool definitions (cache-friendly)

---

## 5. Curation

**Question:** Is the server focused and free of bloat?

| Score | Criteria |
|-------|----------|
| 1 | Monolithic server doing everything. Auto-generated from OpenAPI spec. Many unused tools. |
| 2 | Broad scope. Several tools that overlap or could be consolidated. |
| 3 | Mostly focused. A few tools that could be merged or removed. |
| 4 | Well-scoped. Clear purpose. Minor consolidation opportunities. |
| 5 | "One Server = One Job." Every tool earns its place. No overlap. Parameterized where appropriate. |

**Red flags:**
- Auto-generated from OpenAPI/Swagger
- Admin + user tools mixed together
- Tools with <5% usage rate
- Multiple tools doing slight variations of the same thing

**Good signs:**
- Clear server purpose statement
- Parameterized tools (one `get_info(category)` vs many `get_X`)
- Usage-based pruning evidence
- Role-based separation if needed

---

## 6. Security

**Question:** Is authentication, authorization, and input validation proper?

| Score | Criteria |
|-------|----------|
| 1 | No auth. No input validation. Hardcoded secrets. Mixed read/write risk levels. |
| 2 | Basic auth but no input validation. No read/write separation. |
| 3 | Auth implemented. Some input validation. Read/write mostly separated. |
| 4 | OAuth/proper auth. Good input validation. Read/write separated. Session security. |
| 5 | OAuth 2.1 with PKCE. Strict input validation. Perfect read/write separation. Scope minimization. All known attack vectors mitigated. |

**Red flags:**
- Plaintext tokens in config files
- HTTP instead of HTTPS
- No input sanitization
- Tool that both reads and writes
- Accepting unscoped tokens

**Good signs:**
- OAuth 2.1 with PKCE
- readOnlyHint annotations
- Strict schema validation
- Scope challenges for elevated permissions

---

## 7. LLM Alignment

**Question:** Does the design leverage LLM strengths and avoid weaknesses?

| Score | Criteria |
|-------|----------|
| 1 | Requires long planning chains. Expects strict JSON construction. Uses long identifiers. |
| 2 | Some chaining required. Mix of formats. |
| 3 | Moderate alignment. Returns Markdown. Mostly avoids LLM weaknesses. |
| 4 | Good alignment. Leverages SQL/Markdown. Minimal chaining. Short, clear names. |
| 5 | Excellent alignment. DuckDB/SQL for queries. Markdown/Mermaid for output. Pattern matching for filters. Denormalized data. No multi-step planning. |

**LLM strengths to leverage:**
- SQL queries (especially with DuckDB)
- Markdown and Mermaid diagrams
- Pattern matching (regex, GraphQL)
- Schema comprehension

**LLM weaknesses to avoid:**
- Long planning chains (minimize tool chaining)
- Strict JSON grammar (prefer Markdown/XML)
- Generating long identifiers repeatedly (token-expensive)
- Remembering complex multi-step state

---

---

## 8. Reliability & Idempotency

**Question:** Are tools safe to retry and is output predictable?

| Score | Criteria |
|-------|----------|
| 1 | Write tools create duplicates on retry. No pagination. No size limits on output. |
| 2 | Some idempotency awareness but inconsistent. Limited pagination. |
| 3 | Most write tools handle retries. Basic pagination. Output sizes controlled. |
| 4 | Idempotency keys on write tools. Cursor-based pagination. Structured output where appropriate. |
| 5 | All write tools idempotent. Cursor pagination everywhere. `outputSchema` used. Resource links for large data. Tool annotations set on all tools. |

**Red flags:**
- Write tools without idempotency protection
- List operations without pagination
- Tools returning unbounded data
- Missing tool annotations (`readOnlyHint`, etc.)

**Good signs:**
- `idempotency_key` parameter on create/update tools
- Cursor-based pagination with clear continuation tokens
- `outputSchema` for structured responses
- Resource links for large payloads

---

## 9. Operations & Deployment

**Question:** Is the server production-ready from an operational perspective?

| Score | Criteria |
|-------|----------|
| 1 | No logging. No containerization. No health checks. Runs as raw process with full host access. |
| 2 | Basic logging. Manual deployment. No monitoring. |
| 3 | Structured logging. Docker container. Basic health checks. |
| 4 | JSON-structured logs. Container with non-root user. Health/ready endpoints. Usage metrics tracked. |
| 5 | Full observability (structured logs, usage metrics, error rates, latency). Containerized with resource limits. Versioned. Published to MCP Registry if public. |

**Red flags:**
- Logging to stdout on stdio servers (conflicts with JSON-RPC)
- Running as root in container
- No health checks for remote servers
- No way to track tool usage for curation decisions

**Good signs:**
- Logging to stderr for stdio, structured JSON format
- Non-root container user, resource limits
- Usage frequency tracking per tool
- Semantic versioning with backward-compatible evolution

---

## Scoring Summary Template

```
| Dimension            | Score | Notes |
|----------------------|-------|-------|
| Outcome orientation  |  /5   |       |
| Argument design      |  /5   |       |
| Documentation quality|  /5   |       |
| Token efficiency     |  /5   |       |
| Curation             |  /5   |       |
| Security             |  /5   |       |
| LLM alignment        |  /5   |       |
| Reliability          |  /5   |       |
| Operations           |  /5   |       |
| **Overall**          |  /45  |       |
```

**Interpretation:**
- 38-45: Excellent -- ready for production
- 28-37: Good -- minor improvements needed
- 18-27: Fair -- significant improvements before production
- Below 18: Needs redesign -- fundamental issues present
