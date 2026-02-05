# The 5 Foundational Principles of MCP Server Design

Insights from Jeremiah Lowin (FastMCP creator) and Block Engineering (60+ MCP servers in production).

---

## 1. Outcomes, Not Operations

**The trap:** Exposing atomic operations like a REST API would.

```
BAD: Agent must orchestrate multiple calls
- get_user(user_id)
- get_orders(user_id)
- filter_orders(orders, status)
- check_status(order_id)

GOOD: Single tool, complete outcome
- track_latest_order(email) -> full status update
```

**Design principle:** Top-down from workflows, not bottom-up from API endpoints.

- Do not use the agent as orchestrator/glue -- it's expensive, slow, and stochastic
- Name tools for agent intent, not developer shorthand
- Ask: "What is the agent trying to achieve?" not "What endpoints do I have?"

### The Anti-Pattern: REST-to-MCP Conversion

DO NOT automatically convert REST APIs to MCP servers for production. Auto-generated MCP wrappers violate every principle:
- Too many tools
- Exposes operations, not outcomes
- Verbose, poorly-scoped outputs

**When auto-generation is OK:** Bootstrapping and validation only.
1. Mirror a few key endpoints to verify agent can use the tool
2. Once working, strip out REST mirroring
3. Redesign around outcomes

### Block's Linear MCP Evolution

Real-world example of progressive consolidation:

**V1:** 30+ tools mirroring GraphQL queries
- `get_issue`, `get_issue_labels`, `get_issue_comments`, etc.
- Required 4-6 chained calls for simple queries

**V2:** Consolidated by category
- `get_issue_info(issue_id, info_category)` with category options: details, comments, labels, subscribers, parent, branch_name, children

**V3:** Direct GraphQL access (2 tools total)
- `execute_readonly_query(query, variables)`
- `execute_mutation_query(query, variables)`
- What took 4-6 calls now takes 1

**Note:** V3's `variables: dict` parameter intentionally violates the "Flatten Arguments" principle. This is an acceptable tradeoff when exposing a query language the LLM already understands natively (GraphQL, SQL). The query string itself replaces the need for flat parameters.

### Server Organization: One Server = One Job

Instead of one monolithic server, use purpose-specific servers:

| Server | Job | Example Tools |
|--------|-----|---------------|
| `triage-server` | Issue management | `get_open_issues`, `assign_issue` |
| `deploy-server` | Deployments | `deploy_to_staging`, `rollback` |
| `analytics-server` | Data queries | `query_metrics`, `generate_report` |

Benefits: focused scope (5-15 tools), clearer permissions, independent versioning.

---

## 2. Flatten Your Arguments

**The trap:** Complex nested objects or config dictionaries -- "Mystery Meat" arguments.

```
BAD: Nested config object
search_orders(config: dict)
  "Config should contain: user_email, date_range, status_filter..."

GOOD: Flat, typed arguments
search_orders(
    email: str,
    include_cancelled: bool = false,
    format: Literal["basic", "detailed"] = "basic",
    limit: int = 10
)
```

**Problems with nested arguments:**
- LLMs struggle to construct complex objects correctly
- Some clients send structured arguments as strings (known Claude Desktop bug)
- Documentation drifts between docstrings and system prompts
- Over-configuration: exposing every flag when most have sensible defaults

**Key tactics:**
- Use `Literal` or `Enum` for constrained choices (LLMs handle these well)
- Avoid tightly coupled arguments (where valid values of B depend on A)
- Use typed models with field descriptions only if structure is truly needed
- Strong defaults -- hide complexity behind reasonable defaults

---

## 3. Instructions Are Context

Everything provided is information for the agent's next decision.

### Document Everything

Rich docstrings serve as the agent's primary interface:

```
upload_file(path, owner_email, tags):
    """Upload a file to the shared drive with ownership assignment.

    Handles the complete upload workflow: validates the file,
    assigns ownership, returns a shareable link.

    Args:
        path: Local file path to upload (must exist and be readable)
        owner_email: Email of the user who will own this file
        tags: Optional list of tags (e.g., ["quarterly", "finance"])

    Returns:
        A shareable URL for the uploaded file

    Example:
        upload_file("/tmp/report.pdf", "alice@co.com", ["reports", "2025"])

    Raises:
        FileNotFoundError: If the file doesn't exist
        PermissionError: If the user doesn't have upload rights
    """
```

### Examples Are Contracts

WARNING: LLMs treat examples as strong templates.

- If an example has 2 tags, agents will almost always produce ~2 tags
- If an example uses a specific format, expect that format back
- Consider out-of-distribution examples to avoid over-fitting

### Errors Are Prompts

The LLM sees error messages as information for its next attempt.

```
BAD: raise ValueError()
BAD: raise Exception("CRITICAL FAILURE: Tool is broken!")
     (agent may avoid tool entirely)

GOOD: raise ToolError(
    f"File '{path}' is too large ({size_kb:.0f}KB). "
    f"Maximum size is 400KB. "
    f"Use shell commands like 'head', 'tail', or 'sed -n' to read a subset."
)
```

**Advanced tactic:** Use errors for progressive disclosure -- document common failures and recovery strategies in error messages rather than bloating the main docstring.

### Tool Annotations

MCP defines five annotation properties. Set these on every tool -- clients use them for approval workflows.

```
@mcp.tool(annotations={
    "title": "Track Order Status",
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
})
```

| Property | Purpose | Default |
|----------|---------|---------|
| `title` | Human-readable display name | tool function name |
| `readOnlyHint` | Tool does not modify state | false |
| `destructiveHint` | Tool may delete data or cause irreversible changes | true |
| `idempotentHint` | Calling multiple times with same args has same effect | false |
| `openWorldHint` | Tool interacts with external entities (web, email) | true |

**Client behavior:** ChatGPT and similar clients auto-approve tools with `readOnlyHint: true`. Tools without it require explicit user approval. `destructiveHint: true` tools may trigger additional confirmation dialogs.

---

## 4. Respect the Token Budget

**The brutal math:**

```
200,000 token context / 800 tools = 250 tokens per tool
```

At 250 tokens per tool, barely enough for name + schema, zero room for conversation.

See `references/llm-alignment.md` for detailed token budget math, tool count guidelines, and model-specific context sizes.

### Token Budget Tactics

**Output size control:**
```
Check size before processing:
MAX_FILE_SIZE = 400KB
If file > MAX_FILE_SIZE:
    Return actionable error with recovery strategy
```

**Strategies for large outputs:**
1. **Throw actionable error** -- let agent recover with alternative approach
2. **Truncate with notice** -- return partial content with clear truncation note
3. **Paginate** -- let model request pages (trade-off: more tool calls)
4. **Summarize** -- run summarizer on large content before returning
5. **"Verbose" tools** -- separate tool or resource for full details (progressive disclosure)

### Prompt Caching Consideration

- Avoid dynamic data in instructions (timestamps invalidate cache)
- Check metrics: `cache_read_input_tokens` vs `cache_creation_input_tokens`
- Dynamically selecting tools/examples also invalidates cache

---

## 5. Curate Ruthlessly

> "Start with what works, then tear it down to the essentials."

### The Trap vs The Fix

| The Trap | The Fix |
|----------|---------|
| 50+ tools with long descriptions | 5-15 tools per server |
| "Everything our API can do" | One Server = One Job |
| Admin + User tools mixed | Separate by role/permission level |
| Tools added "just in case" | Prune unused tools based on logs |

### Consolidation Techniques

**Parameterized category tools:**
Instead of 10 separate `get_X` tools, use one `get_info(category)` with a `Literal` parameter.

**Direct query tools:**
Instead of many filtered search tools, expose a query language the LLM already knows (SQL, GraphQL). LLMs are excellent at writing SQL queries.

**Periodic pruning:**
Track tool usage in production logs. Remove tools that are never or rarely called. If a tool is used <5% of the time, consider making it a parameter of another tool or removing it entirely.

### Block's Calendar MCP Example

**V1:** Thin API wrapper (4 tools)
- list_calendars, list_calendar_events, retrieve_timezone, retrieve_free_busy_slots
- Cannot answer "How many meetings did I have last month?"

**V2:** DuckDB + SQL (1 tool)
- query_database(sql, time_min, time_max)
- Leverages LLM's SQL strength
- Finding common meeting times = one call with a SQL query
