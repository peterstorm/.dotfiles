#!/usr/bin/env bash
# Contract: pi auto-continue after a model-triggered /reload-runtime.
#
# The reload-runtime extension queues /reload-runtime as a deferred command
# (pi-extension-command-after-idle.patch) and journals a "pending"
# reload-runtime-auto-continue entry. After the reload, the reloaded extension
# instance consumes the marker in its session_start handler and sends the
# "[runtime-reloaded] Continue from where you left off." prompt, so the agent
# resumes without a human prompt — the reload-side twin of
# tests/pi-compaction-autocontinue-contract.sh.
#
# This contract drives the deployed pi CLI (print mode, the same binding the
# TUI uses) against a fake OpenAI-compatible model server and asserts, end to
# end in one session file:
#   - the pending marker is journaled before the reload;
#   - the run completes normally and the deferred command reloads;
#   - the reloaded instance consumes the marker exactly once (pending -> consumed).
# The continuation turn itself ("[runtime-reloaded]" -> assistant response) is
# asserted on a long-lived session by pi/tests/reload-autocontinue.test.ts: in
# one-shot print mode the process tears down while the extension-triggered turn
# is still starting, so that turn cannot be asserted deterministically here —
# and a finished one-shot prompt should not be resumed anyway (the same
# completed-answer carve-out as the compaction auto-continue).
#
# Requires: pi on PATH (the Nix-built package under test), node on PATH.
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null || fail "pi is not on PATH"
command -v node >/dev/null || fail "node is not on PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
EXT_SOURCE="$HERE/../pi/extensions/reload-runtime.ts"
[ -f "$EXT_SOURCE" ] || fail "missing extension source at $EXT_SOURCE"

PI_BIN="$(readlink -f "$(command -v pi)")"
PI_DIST="$(dirname "$PI_BIN")/../lib/node_modules/@earendil-works/pi-coding-agent/dist"
[ -d "$PI_DIST" ] || fail "cannot locate pi dist under $PI_BIN"

TMP="$(mktemp -d /tmp/pi-reload-contract.XXXXXX)"
PORT=$(( 8600 + RANDOM % 1400 ))
cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fake OpenAI-compatible chat-completions server. Content-based classification:
#   continue -> the last user message carries the "[runtime-reloaded]" marker
#   wrap     -> a reload_runtime tool result exists (tool ran; finish the turn)
#   initial  -> otherwise; answer with a reload_runtime tool call
# ---------------------------------------------------------------------------
cat > "$TMP/server.js" <<'EOF'
import http from "node:http";
const PORT = Number(process.env.FAKE_PORT);
function textOf(msg) {
  if (!msg) return "";
  if (typeof msg.content === "string") return msg.content;
  if (Array.isArray(msg.content)) return msg.content.filter((c) => c && c.type === "text").map((c) => c.text).join("\n");
  return "";
}
function classify(body) {
  const messages = body.messages ?? [];
  const lastUser = [...messages].reverse().find((m) => m.role === "user");
  if (lastUser && textOf(lastUser).includes("[runtime-reloaded]")) return "continue";
  // Pi maps tool results to {role: "tool", tool_call_id, content} without the tool name,
  // so any tool message means reload_runtime already ran: finish the turn.
  if (messages.some((m) => m.role === "tool")) return "wrap";
  return "initial";
}
function sse(res, payload) {
  res.writeHead(200, { "content-type": "text/event-stream" });
  const chunk = (obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);
  const base = { id: "chatcmpl-fake", object: "chat.completion.chunk", created: 0, model: "fakemodel" };
  if (payload.text) chunk({ ...base, choices: [{ index: 0, delta: { content: payload.text }, finish_reason: null }] });
  if (payload.toolCalls) {
    for (const [i, tc] of payload.toolCalls.entries()) {
      chunk({ ...base, choices: [{ index: 0, delta: { tool_calls: [{ index: i, id: tc.id, type: "function", function: { name: tc.name, arguments: tc.arguments } }] }, finish_reason: null }] });
    }
    chunk({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] });
  } else {
    chunk({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] });
  }
  chunk({ ...base, choices: [], usage: { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 } });
  res.write("data: [DONE]\n\n");
  res.end();
}
http.createServer((req, res) => {
  if (req.method !== "POST" || !req.url?.includes("/chat/completions")) { res.writeHead(404).end(); return; }
  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    let body; try { body = JSON.parse(raw); } catch { res.writeHead(400).end(); return; }
    const kind = classify(body);
    if (kind === "continue") sse(res, { text: "Continued after reload." });
    else if (kind === "wrap") sse(res, { text: "Reload requested; wrapping up." });
    else sse(res, { text: "Calling reload.", toolCalls: [{ id: "call_1", name: "reload_runtime", arguments: "{}" }] });
  });
}).listen(PORT, "127.0.0.1");
EOF

home="$TMP/home" work="$TMP/work"
mkdir -p "$home/.pi/agent/extensions" "$work"
cp "$EXT_SOURCE" "$home/.pi/agent/extensions/reload-runtime.ts"
cat > "$home/.pi/agent/models.json" <<EOF
{
  "providers": {
    "fakeprov": {
      "baseUrl": "http://127.0.0.1:$PORT/v1",
      "api": "openai-completions",
      "apiKey": "fake-key",
      "models": [{
        "id": "fakemodel",
        "name": "Fake Model",
        "reasoning": false,
        "input": ["text"],
        "contextWindow": 100000,
        "maxTokens": 8192,
        "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
      }]
    }
  }
}
EOF
cat > "$home/.pi/agent/settings.json" <<'EOF'
{
  "compaction": { "enabled": false },
  "retry": { "enabled": false }
}
EOF
FAKE_PORT="$PORT" node "$TMP/server.js" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
sleep 0.5

rc=0
(cd "$work" && HOME="$home" node "$PI_DIST/cli.js" -p "Call the reload_runtime tool." \
    --provider fakeprov --model fakemodel \
    > "$TMP/out.txt" 2> "$TMP/err.txt") || rc=$?
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=

[ "$rc" = 0 ] || fail "pi exited $rc (stderr: $(head -c 300 "$TMP/err.txt"))"

session_file="$(ls -t "$home"/.pi/agent/sessions/*/*.jsonl 2>/dev/null | head -1)" || true
[ -n "$session_file" ] || fail "no session file written"

node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
  const entries = [];
  for (const line of lines) {
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.type === "custom" && e.customType === "reload-runtime-auto-continue") {
      entries.push({ kind: "marker", marker: e.data?.kind });
    } else if (e.type === "message") {
      const text = typeof e.message.content === "string" ? e.message.content
        : Array.isArray(e.message.content) ? e.message.content.map((c) => c.text ?? "").join("") : "";
      entries.push({ kind: "message", role: e.message.role, stopReason: e.message.stopReason ?? "", text });
    }
  }
  const markers = entries.filter((e) => e.kind === "marker");
  const kinds = markers.map((m) => m.marker);
  // Exactly one pending and one consumed, in that order: a second pending would
  // mean the tool loop re-entered (model kept calling reload_runtime); a missing
  // consumed would mean the reload never re-emitted session_start.
  if (!(kinds.length === 2 && kinds[0] === "pending" && kinds[1] === "consumed")) {
    console.error(`FAIL: expected exactly [pending, consumed] markers, got ${JSON.stringify(kinds)}`);
    process.exit(1);
  }
  const consumedIndex = entries.findIndex((e) => e.kind === "marker" && e.marker === "consumed");
  const wrapped = entries.slice(0, consumedIndex).some((e) => e.kind === "message" && e.role === "assistant" && e.stopReason === "stop");
  if (!wrapped) {
    console.error("FAIL: the agent turn did not complete with a stop response before the reload");
    process.exit(1);
  }
' "$session_file" || fail "session transcript assertions failed (see above)"

if grep -q "Extension error" "$TMP/err.txt"; then
  fail "extension errors surfaced: $(head -c 300 "$TMP/err.txt")"
fi

printf 'OK: pi reload auto-continue (pending -> reload -> consumed; continuation turn covered by the SDK contract)\n'
