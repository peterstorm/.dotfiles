#!/usr/bin/env bash
# Contract: pi monitor extension against the deployed binary (print mode).
#
# The monitor tool spawns a background command and returns immediately; when the
# command exits, the extension injects the completion (exit code + output tail) as
# a custom message. In one-shot `pi -p` a fast command's completion lands while the
# turn is still wrapping, so it is queued as a steer and delivered by the post-run
# continue — this contract asserts that full chain end to end:
#
#   started journal entry -> finished entry (exit 0) -> injected custom message
#   carrying the command's output -> final assistant stop (exit 0)
#
# Long-running monitors whose completion lands after teardown are covered by the
# SDK-level contract (pi/tests/monitor-e2e.test.ts), which runs on a live session.
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
EXT_SOURCE="$HERE/../pi/extensions/monitor"
[ -f "$EXT_SOURCE/index.ts" ] || fail "missing extension source at $EXT_SOURCE"
[ -f "$EXT_SOURCE/state.ts" ] || fail "missing extension state at $EXT_SOURCE/state.ts"

PI_BIN="$(readlink -f "$(command -v pi)")"
PI_DIST="$(dirname "$PI_BIN")/../lib/node_modules/@earendil-works/pi-coding-agent/dist"
[ -d "$PI_DIST" ] || fail "cannot locate pi dist under $PI_BIN"

TMP="$(mktemp -d /tmp/pi-monitor-contract.XXXXXX)"
PORT=$(( 8900 + RANDOM % 300 ))
cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Fake OpenAI-compatible server. Content-based classification:
#   wrap    -> a tool result exists (monitor ran; finish the turn)
#   initial -> otherwise; answer with a monitor tool call
cat > "$TMP/server.js" <<'EOF'
import http from "node:http";
const PORT = Number(process.env.FAKE_PORT);
function classify(body) {
  const messages = body.messages ?? [];
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
    if (kind === "wrap") sse(res, { text: "The monitor is running; nothing to do until it reports." });
    else sse(res, { text: "Starting the monitor.", toolCalls: [{ id: "call_1", name: "monitor", arguments: JSON.stringify({ name: "ci", command: "echo monitor-contract-done" }) }] });
  });
}).listen(PORT, "127.0.0.1");
EOF

home="$TMP/home" work="$TMP/work"
mkdir -p "$home/.pi/agent/extensions/monitor" "$work"
cp "$EXT_SOURCE/index.ts" "$EXT_SOURCE/state.ts" "$home/.pi/agent/extensions/monitor/"
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
(cd "$work" && HOME="$home" node "$PI_DIST/cli.js" -p "Watch: echo monitor-contract-done" \
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
    if (e.type === "custom" && e.customType === "monitor") {
      entries.push({ kind: "monitor", data: e.data ?? {} });
    } else if (e.type === "custom_message" && e.customType === "monitor") {
      entries.push({ kind: "message", text: typeof e.content === "string" ? e.content : "" });
    } else if (e.type === "message") {
      const text = typeof e.message.content === "string" ? e.message.content
        : Array.isArray(e.message.content) ? e.message.content.map((c) => c.text ?? "").join("") : "";
      entries.push({ kind: "assistant", role: e.message.role, stopReason: e.message.stopReason ?? "", text });
    }
  }
  const started = entries.filter((e) => e.kind === "monitor" && e.data.kind === "started");
  const finished = entries.filter((e) => e.kind === "monitor" && e.data.kind === "finished");
  if (started.length !== 1) {
    console.error(`FAIL: expected exactly one started monitor entry, got ${started.length}`);
    process.exit(1);
  }
  const spec = started[0].data.spec ?? {};
  if (!(typeof spec.pid === "number" && spec.pid > 0 && typeof spec.logPath === "string" && spec.logPath.includes("pi-monitor-"))) {
    console.error(`FAIL: started entry has a malformed spec: ${JSON.stringify(spec).slice(0, 200)}`);
    process.exit(1);
  }
  if (finished.length !== 1 || finished[0].data.exitCode !== 0) {
    console.error(`FAIL: expected exactly one finished entry with exit 0, got ${JSON.stringify(finished.map((f) => f.data.exitCode))}`);
    process.exit(1);
  }
  const completions = entries.filter((e) => e.kind === "message" && e.text.includes("monitor-contract-done"));
  if (completions.length !== 1 || !completions[0].text.includes("Monitor '\''ci'\'' finished (exit 0)")) {
    console.error(`FAIL: expected one completion message carrying the output, got ${JSON.stringify(completions)}`);
    process.exit(1);
  }
  const finishedIndex = entries.findIndex((e) => e.kind === "monitor" && e.data.kind === "finished");
  const stopped = entries.slice(finishedIndex + 1).some((e) => e.kind === "assistant" && e.role === "assistant" && e.stopReason === "stop");
  if (!stopped) {
    console.error("FAIL: no assistant stop after the completion was delivered");
    process.exit(1);
  }
' "$session_file" || fail "session transcript assertions failed (see above)"

if grep -q "Extension error" "$TMP/err.txt"; then
  fail "extension errors surfaced: $(head -c 300 "$TMP/err.txt")"
fi

printf 'OK: pi monitor (started -> background exit -> finished entry -> completion message -> assistant stop)\n'
