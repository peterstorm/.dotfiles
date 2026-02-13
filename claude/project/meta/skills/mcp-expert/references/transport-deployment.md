# Transport, Deployment & Operations Guide

Covers transport selection, containerization, testing, versioning, observability, and MCP registry/discovery.

---

## Transport Selection

MCP supports two official transports. Choose based on deployment model.

### stdio (Local)

- Communication over standard input/output
- Used for local servers (IDE extensions, CLI tools, developer tooling)
- Maximum performance -- no network overhead
- Session is implicit in the process lifecycle
- **Use when:** Server runs on same machine as client

**Local server lifecycle:**
- Handle clean shutdown when client closes stdin
- Don't assume process persists between conversations
- Avoid heavy initialization -- clients may start/stop frequently
- Log to stderr (stdout is JSON-RPC channel)

### Streamable HTTP (Remote)

Introduced spec 2025-03-26, replacing deprecated HTTP+SSE transport.

- Single HTTP endpoint for bidirectional messaging
- Server responds with standard HTTP or SSE streaming per-request
- Supports multiple concurrent client connections
- **Use when:** Server deployed remotely, needs horizontal scaling, or serves multiple clients

**Key details:**
- Session management via `Mcp-Session-Id` header (optional, server-assigned during init)
- If server returns session ID, client must include in all subsequent requests
- Server can terminate sessions at any time (returns 404 for expired)
- Stream resumability via `Last-Event-ID` header

### SSE Transport (Deprecated)

Old HTTP+SSE transport (two endpoints: `/sse` and `/messages`) is deprecated as of 2025-03-26. If supporting legacy clients:
- Implement Streamable HTTP as primary
- Add SSE fallback detection
- Plan to remove once clients migrate

### Protocol Versioning

- All HTTP requests must include `MCP-Protocol-Version` header after version negotiation
- If header missing and version can't be inferred, servers should default to `2025-03-26`
- JSON-RPC batching removed in 2025-06-18 spec (breaking change)

---

## Containerization

### Why Containerize

Running MCP servers via `npx` or `uvx` executes arbitrary code with full host access -- filesystem, env vars, network, credentials. Not sustainable for production.

**Docker containers provide:**
- Process isolation from host
- Controlled filesystem access (read-only mounts where possible)
- Network restrictions (egress controls)
- Reproducible environments
- Cryptographic signatures and vulnerability scanning

### Best Practices

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
# Run as non-root
RUN useradd -m mcpuser
USER mcpuser
CMD ["python", "server.py"]
```

### Remote Server Deployment

- Implement `/health` and `/ready` endpoints
- Set memory and CPU limits
- Use sticky sessions or shared state store for horizontal scaling
- Handle SIGTERM, complete in-flight requests, close sessions gracefully

---

## Testing

### Unit Testing

- Test each tool's logic independently
- Validate inputs conform to declared `inputSchema`
- Validate outputs conform to declared `outputSchema` (if using structured output)
- Test error paths -- verify error messages are actionable and recoverable
- Test edge cases: empty inputs, maximum sizes, special characters

### Integration Testing

- Use [MCP Inspector](https://modelcontextprotocol.io/docs/tools/inspector) or SDK test clients
- Test full lifecycle: initialization -> capability negotiation -> tool calls -> shutdown
- Verify tool listing returns correct schemas and documentation
- Test session management (for Streamable HTTP servers)

### Security Testing

- **Prompt injection:** Craft inputs that attempt to override tool instructions
- **Tool poisoning:** Verify descriptions don't contain injectable content
- **Command injection:** Test params with shell metacharacters
- **Path traversal:** Test file paths with `../` sequences
- **SSRF:** Test URL params with internal network addresses
- Tools like [Promptfoo](https://www.promptfoo.dev/docs/red-team/mcp-security-testing/) have MCP-specific plugins

### Client Compatibility

Test against multiple clients -- they all behave differently:

- **Claude Desktop:** Caches tools in SQLite on first contact; may send structured args as strings; hashes tools and doesn't always update on server change
- **VS Code / Cursor / Windsurf:** Different tool display and approval UIs
- **Custom clients:** May not support all spec features (notifications, elicitation)

### CI/CD Integration

- Add MCP protocol compliance tests to CI pipeline
- Validate schemas on every commit
- Run security tests automatically
- Test backward compatibility when updating tool definitions

---

## Observability & Logging

### What to Log

- Every tool invocation: timestamp, user ID, tool name, sanitized arguments, duration, output size
- Errors with full context
- Token consumption estimates per tool call
- Authentication events: token validation, scope checks, failures

### How to Log

- Structure logs as JSON for machine parsing
- Log to stderr for stdio servers (stdout is protocol channel)
- Use MCP spec's `logging` capability for client-visible logs:

```python
await server.send_log(level="warning", data="Query returned 10,000 rows, truncating to 100")
```

### Metrics to Track

| Metric | Purpose |
|--------|---------|
| Tool usage frequency | Informs curation decisions (prune unused tools) |
| Error rates per tool | Identify unreliable tools |
| Response sizes | Catch tools that blow token budgets |
| Latency per tool | Slow tools degrade agent experience |
| Schema cache hit rates | Monitor prompt caching effectiveness |

---

## Versioning & Evolution

### Version Your Server

- Use semantic versioning for server and tools
- Include version in server metadata during initialization
- `MCP-Protocol-Version` header handles spec version negotiation

### Evolving Tools Safely

| Change | Breaking? | Notes |
|--------|-----------|-------|
| Adding a tool | Safe | Existing agents unaffected |
| Removing a tool | Breaking | Deprecate first with clear docs |
| Changing tool schema | Potentially | Some clients cache aggressively |
| Adding optional params | Safe | Existing calls still work |
| Removing params / changing types | Breaking | |

### Client Caching Problem

Some clients (notably Claude Desktop) hash tool definitions and may not pick up changes. Design defensively:
- Test that tool changes are reflected in the client
- Users may need to restart or clear caches
- Consider versioning tool names as last resort (`search_v2`)

---

## MCP Registry & Discovery

### Official MCP Registry

The [MCP Registry](https://registry.modelcontextprotocol.io) launched in preview September 2025. Provides:
- Centralized discovery -- machine-readable catalog clients can query
- Federated distribution -- sub-registries build on top
- Standardized `server.json` definitions for metadata and configuration

Register public servers at the official MCP Registry.

### Docker MCP Catalog

[Docker's MCP Catalog](https://hub.docker.com/catalogs/mcp) provides containerized MCP servers with security scanning, signatures, and SBOMs. 1M+ pulls.

### GitHub MCP Registry

[GitHub's MCP Registry](https://github.com/mcp) curates verified MCP servers with one-click installation for VS Code and GitHub-integrated clients.

### `.well-known` Discovery

Servers will advertise capabilities through `.well-known` URLs, allowing clients to discover what a server can do without connecting first.

---

## Advanced: Sampling & Roots

### Sampling

MCP allows servers to request LLM completions from the client via `sampling/complete`. Enables server-side intelligence without bundling an LLM SDK.

Use cases: data processing pipelines where server needs LLM intelligence but wants model-agnostic design.

**Security note:** Sampling creates new attack vectors. A malicious server can craft prompts that trick the client's LLM.

### Roots

Roots define scope boundaries -- what resources, tools, and prompts are visible to a client. Useful for:
- Multi-tenant servers (each user sees different capabilities)
- Project-scoped isolation (each project root exposes different tools)
- Environment separation (dev vs staging vs prod)

---

## Client Reality Check

Not all clients are spec-compliant. Design defensively.

**Claude Desktop quirks:**
- Caches tools in SQLite on first contact
- Ignores spec-compliant features like notifications
- May send structured arguments as strings (FastMCP auto-deserializes)
- Hashes tools and doesn't update even if server changes

**If you control the client:** Much more flexibility -- progressive disclosure, custom routing, optimized token budgets, full elicitation support.

**If you don't control the client:** Assume worst-case. Document everything in tool docstrings. Don't rely on elicitation or annotations being supported. Test against specific clients your users use.

---

## Resources

- [MCP Specification (latest)](https://modelcontextprotocol.io/specification)
- [MCP Security Best Practices](https://modelcontextprotocol.io/specification/draft/basic/security_best_practices)
- [MCP Registry](https://registry.modelcontextprotocol.io)
- [Block's MCP Playbook](https://engineering.block.xyz/blog/blocks-playbook-for-designing-mcp-servers)
- [FastMCP Documentation](https://github.com/jlowin/fastmcp)
- [Docker MCP Catalog](https://hub.docker.com/catalogs/mcp)
- [MCP Inspector (Testing)](https://modelcontextprotocol.io/docs/tools/inspector)
- [Promptfoo MCP Security Testing](https://www.promptfoo.dev/docs/red-team/mcp-security-testing/)
