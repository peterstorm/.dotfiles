# LLM Alignment & Token Budget Guide

How to design MCP servers that work with -- not against -- LLM capabilities.

---

## Token Budget Math

```
200,000 token context / N tools = tokens available per tool

Example:
  800 tools = 250 tokens/tool (impossible -- no room for conversation)
  100 tools = 2,000 tokens/tool (tight)
   50 tools = 4,000 tokens/tool (workable but degraded)
   15 tools = 13,333 tokens/tool (comfortable)
    5 tools = 40,000 tokens/tool (plenty)
```

**Remember:** This is per agent, not per server. If an agent connects to three 20-tool servers, that's 60 tools competing for context.

**Note:** 200K tokens is used as a reference baseline (Claude's context window). Other models differ (Gemini: 1M+, GPT-4: 128K). Adjust the math per model. Regardless of window size, performance degrades with large contexts -- more tools always means more noise for the agent to filter through.

### What Consumes Tokens

Per tool:
- Tool name and description
- JSON schema for arguments (types, descriptions, defaults, enums)
- Return type schema
- Server instructions

Per conversation:
- System prompt
- Conversation history
- Tool call results (the biggest variable)

---

## Output Size Management

### The Problem

A single tool returning 50KB of JSON can consume 25% of context. Multiply by a few tool calls and the agent runs out of memory for actual reasoning.

### Strategies (ordered by preference)

**1. Summaries + IDs**
Return human-readable summary with identifiers for drill-down.

```
GOOD:
  "Found 23 orders for alice@co.com. Most recent: #12345 (shipped, arriving Jan 15).
   Use get_order_details(order_id) for full information."

BAD:
  [full JSON array of 23 order objects with all fields]
```

**2. Size limits with actionable errors**
Check content size before returning.

```
if file_size > 400KB:
    error("File '{path}' is {size}KB. Max is 400KB. "
          "Use 'head', 'tail', or 'sed -n' to read a subset.")
```

**3. Truncation with notice**
Return partial content with clear indication.

```
"Showing first 50 of 234 results. Use offset=50 to see next page."
```

**4. Pagination**
Let agent request pages. Trade-off: more tool calls, but controlled output size.

**5. Progressive disclosure ("verbose" tools)**
Default tool returns summary. Separate tool or parameter for full details.

```
get_issues(project, limit) -> summaries
get_issue_details(issue_id) -> full content
```

---

## LLM Strengths to Leverage

### SQL Queries

LLMs are excellent at writing SQL. Instead of many filtered search tools, expose a query interface.

**Block's calendar evolution:**
- Before: `list_calendars()` + `list_events(calendar, timeMax, timeMin)` + `retrieve_free_busy()`
- After: `query_database(sql)` with DuckDB tables

```sql
-- Agent writes this naturally:
SELECT * FROM free_slots(
    ['alice@co.com', 'bob@co.com'],
    '2025-05-13T09:00:00Z',
    '2025-05-17T18:00:00Z'
);
```

**When to use SQL approach:**
- Data has clear structure (tables, columns)
- Multiple filter/aggregation patterns needed
- Current tool set requires chaining for complex queries

**Implementation notes:**
- Denormalize data for fewer joins (LLMs struggle with complex joins)
- Use short table/column names (each reference costs tokens)
- Provide schema in server instructions

### Markdown and Mermaid

Return diagrams and formatted content as text. LLMs understand and produce Markdown/Mermaid natively.

```
GOOD: Return Mermaid diagram as text
BAD: Return image URL or binary

GOOD: Return Markdown-formatted report
BAD: Return raw HTML
```

### Pattern Matching

Let LLMs write:
- GraphQL queries (they understand schema + query syntax)
- Regular expressions
- JQ/JSONPath expressions
- Template strings

---

## LLM Weaknesses to Avoid

### Long Planning Chains

Each tool call in a chain sends the entire conversation history. Chains are:
- Token-expensive (cumulative context growth)
- Slow (round-trip latency per call)
- Fragile (stochastic -- each step can go wrong)

**Rule of thumb:** If a workflow requires 4+ sequential tool calls, redesign as a single outcome-oriented tool.

### Strict JSON Construction

LLMs occasionally produce malformed JSON, especially:
- Complex nested structures
- Arrays of objects with many fields
- Deeply nested optional fields

**Prefer:**
- Markdown/XML for complex output
- Flat argument structures for input
- Structured outputs (constrained decoding) when JSON is required

### Long Identifiers

Every time the agent references a long table name, column name, or ID, it costs tokens.

```
BAD: user_authentication_sessions_with_metadata (5 tokens every reference)
GOOD: auth_sessions (2 tokens)
```

This compounds across a conversation with multiple references.

### Multi-Step State Management

LLMs have no persistent memory between turns beyond the conversation context. Do not design tools that require the agent to maintain state across multiple calls.

```
BAD:
  step1: create_draft(data) -> draft_id
  step2: add_items(draft_id, items)
  step3: review_draft(draft_id) -> changes
  step4: finalize_draft(draft_id)

GOOD:
  create_order(data, items) -> complete order
```

---

## Prompt Caching Optimization

Modern LLM APIs cache prompt prefixes. MCP tool definitions are part of this prefix.

### What Breaks Caching

- Dynamic data in tool descriptions (timestamps, counts)
- Dynamically selecting which tools to expose per request
- Frequently changing tool schemas

### What Preserves Caching

- Static tool definitions (same schema every call)
- Session-created timestamps instead of current timestamps
- Stable tool set across conversations
- Monitoring `cache_read_input_tokens` vs `cache_creation_input_tokens`

### Cache-Friendly Design

```
BAD (in tool description):
  "Last updated: 2025-01-15T10:30:00Z. Currently 1,234 items in database."

GOOD (in tool description):
  "Query the items database. Returns results with last-updated timestamps."
```

---

## Quick Reference: Design Implications

| LLM Capability | Design Implication |
|----------------|-------------------|
| Excellent at SQL | Expose DuckDB/SQL for structured queries |
| Understands Markdown | Return formatted text, not raw data |
| Good at pattern matching | Let agents write GraphQL, regex, JQ |
| Schema comprehension | Provide schemas in server instructions |
| Weak at long chains | One tool = one complete outcome |
| Weak at strict JSON | Prefer Markdown for complex output |
| Weak at long names | Keep identifiers short |
| No persistent memory | Don't require cross-call state |
