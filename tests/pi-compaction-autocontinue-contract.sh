#!/usr/bin/env bash
# Contract: pi auto-continue after auto-compaction.
#
# The pi overlay patch pi-autocontinue-after-compact.patch makes threshold
# auto-compaction resume the agent turn instead of stalling for input. An
# earlier revision of that patch returned true from _runAutoCompaction
# unconditionally, but agent.continue() rejects an assistant-tailed
# transcript — and the rebuilt post-compaction context always ends with the
# just-finished turn's final assistant message — so every auto-continue threw
# "Cannot continue from message role: assistant" and killed the run.
#
# This contract drives the deployed pi against a fake OpenAI-compatible
# model server and asserts both resume shapes:
#   A: completed turn over threshold -> compaction, then a queued
#      "[auto-compacted]" continuation prompt, then a continued assistant
#      response (exit 0).
#   B: mid-turn error over threshold -> compaction, the failed assistant
#      message dropped from working context, then a resumed assistant
#      response (exit 0).
#
# Requires: pi on PATH (the Nix-built package under test), node on PATH.
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null || fail "pi is not on PATH"
command -v node >/dev/null || fail "node is not on PATH"
PI_BIN="$(readlink -f "$(command -v pi)")"
PI_DIST="$(dirname "$PI_BIN")/../lib/node_modules/@earendil-works/pi-coding-agent/dist"
[ -d "$PI_DIST" ] || fail "cannot locate pi dist under $PI_BIN"

TMP="$(mktemp -d /tmp/pi-compaction-contract.XXXXXX)"
PORT=$(( 8400 + RANDOM % 1500 ))
cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fake OpenAI-compatible chat-completions server.
# Request classification (content-based, order-independent):
#   summarize      -> any message contains the pi summarization system prompt
#   nudge-continue -> last user message carries the "[auto-compacted]" marker
#   resume/fail    -> transcript ends with a tool result; fail only before the
#                     compaction summary (COMPACT-SUMMARY-MARKER) is in context
#   initial        -> otherwise; scenario B answers with a tool call, A with text
# Usage numbers: initial responses report prompt=1900/completion=50 against a
# 2000-token window with reserveTokens=100 — above the compaction threshold
# (1900) but below the silent-overflow check (input <= contextWindow).
# ---------------------------------------------------------------------------
cat > "$TMP/server.js" <<'EOF'
import http from "node:http";
const PORT = Number(process.env.FAKE_PORT);
const SCENARIO = process.env.FAKE_SCENARIO;
const LONG = "x".repeat(1200); // keeps the assistant message past keepRecentTokens
function textOf(msg) {
  if (!msg) return "";
  if (typeof msg.content === "string") return msg.content;
  if (Array.isArray(msg.content)) return msg.content.filter((c) => c && c.type === "text").map((c) => c.text).join("\n");
  return "";
}
function classify(body) {
  const messages = body.messages ?? [];
  const last = messages[messages.length - 1];
  const allText = messages.map(textOf).join("\n");
  const lastText = last?.role === "user" ? textOf(last) : "";
  if (lastText.includes("[auto-compacted]")) return "nudge-continue";
  if (allText.includes("context summarization assistant")) return "summarize";
  if (last?.role === "tool") return allText.includes("COMPACT-SUMMARY-MARKER") ? "resume" : "fail";
  return "initial";
}
function sse(res, payload, usage) {
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
  chunk({ ...base, choices: [], usage: { prompt_tokens: usage.prompt, completion_tokens: usage.completion, total_tokens: usage.prompt + usage.completion } });
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
    if (kind === "fail") {
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: "Internal Server Error", type: "server_error" } }));
      return;
    }
    if (kind === "summarize") { sse(res, { text: "COMPACT-SUMMARY-MARKER Summary: user asked hello; assistant replied." }, { prompt: 10, completion: 20 }); return; }
    if (kind === "nudge-continue") { sse(res, { text: "Continued response after compaction. " + LONG }, { prompt: 150, completion: 30 }); return; }
    if (kind === "resume") { sse(res, { text: "Resumed response after compaction. " + LONG }, { prompt: 160, completion: 30 }); return; }
    if (SCENARIO === "B") {
      sse(res, { text: "Working on it. " + LONG, toolCalls: [{ id: "call_1", name: "read", arguments: JSON.stringify({ path: "/etc/hostname" }) }] }, { prompt: 1900, completion: 50 });
    } else {
      sse(res, { text: "First response. " + LONG }, { prompt: 1900, completion: 50 });
    }
  });
}).listen(PORT, "127.0.0.1");
EOF

run_scenario() {
  local scenario=$1
  local home="$TMP/home-$scenario" work="$TMP/work-$scenario"
  mkdir -p "$home/.pi/agent" "$work"
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
        "contextWindow": 2000,
        "maxTokens": 2000,
        "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
      }]
    }
  }
}
EOF
  cat > "$home/.pi/agent/settings.json" <<'EOF'
{
  "compaction": { "enabled": true, "reserveTokens": 100, "keepRecentTokens": 20 },
  "retry": { "enabled": false }
}
EOF
  FAKE_SCENARIO="$scenario" FAKE_PORT="$PORT" node "$TMP/server.js" > "$TMP/server-$scenario.log" 2>&1 &
  SERVER_PID=$!
  sleep 0.5
  local rc=0
  (cd "$work" && HOME="$home" node "$PI_DIST/cli.js" -p "hello" \
      --provider fakeprov --model fakemodel \
      > "$TMP/out-$scenario.txt" 2> "$TMP/err-$scenario.txt") || rc=$?
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
  echo "$rc"
}

# Summarize the newest session file as TAB lines: type, role, stopReason, text
summarize_session() {
  local home=$1
  local file
  file="$(ls -t "$home"/.pi/agent/sessions/*/*.jsonl 2>/dev/null | head -1)" || true
  [ -n "$file" ] || fail "no session file written"
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
    for (const line of lines) {
      let e; try { e = JSON.parse(line); } catch { continue; }
      if (e.type === "message") {
        const m = e.message;
        const text = typeof m.content === "string" ? m.content
          : Array.isArray(m.content) ? m.content.map((c) => c.text ?? (c.type === "toolCall" ? `CALL ${c.name}` : c.type)).join("|")
          : "";
        console.log(`${m.role}\t${m.stopReason ?? ""}\t${text.slice(0, 60).replace(/\n/g, " ")}`);
      } else if (e.type === "compaction") {
        console.log(`COMPACTION\t\t${(e.summary ?? "").slice(0, 40)}`);
      } else {
        console.log(e.type);
      }
    }
  ' "$file"
}

assert_no_continue_error() {
  local scenario=$1
  if grep -q "Cannot continue from message role" "$TMP/err-$scenario.txt"; then
    fail "scenario $scenario: 'Cannot continue from message role' surfaced (stderr: $(head -c 200 "$TMP/err-$scenario.txt"))"
  fi
}

# --- Scenario A: completed turn over threshold -> nudge + continuation -----
rc_A="$(run_scenario A)"
[ "$rc_A" = 0 ] || fail "scenario A: pi exited $rc_A (stderr: $(head -c 300 "$TMP/err-A.txt"))"
assert_no_continue_error A
transcript_A="$(summarize_session "$TMP/home-A")"
echo "$transcript_A" | grep -q $'^COMPACTION\t' || fail "scenario A: no compaction entry in session"
echo "$transcript_A" | grep -q $'^user\t\t\[auto-compacted\]' || fail "scenario A: no '[auto-compacted]' continuation prompt delivered"
# An assistant message with stopReason=stop must follow the nudge.
node -e '
  const fs = require("fs");
  const file = process.argv[1];
  const lines = fs.readFileSync(file, "utf8").trim().split("\n");
  let sawNudge = false, sawContinued = false, sawCompaction = false;
  for (const line of lines) {
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.type === "compaction") { sawCompaction = true; continue; }
    if (e.type !== "message") continue;
    const m = e.message;
    if (m.role === "user" && JSON.stringify(m.content ?? []).includes("[auto-compacted]")) sawNudge = true;
    if (sawNudge && sawCompaction && m.role === "assistant" && m.stopReason === "stop") sawContinued = true;
  }
  process.exit(sawContinued ? 0 : 1);
' "$(ls -t "$TMP/home-A"/.pi/agent/sessions/*/*.jsonl | head -1)" \
  || fail "scenario A: no continued assistant response after the nudge"

# --- Scenario B: mid-turn error over threshold -> drop + resume -------------
rc_B="$(run_scenario B)"
[ "$rc_B" = 0 ] || fail "scenario B: pi exited $rc_B (stderr: $(head -c 300 "$TMP/err-B.txt"))"
assert_no_continue_error B
transcript_B="$(summarize_session "$TMP/home-B")"
echo "$transcript_B" | grep -q $'^COMPACTION\t' || fail "scenario B: no compaction entry in session"
node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
  let sawError = false, sawCompaction = false, sawResumed = false;
  for (const line of lines) {
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (e.type === "message" && e.message.role === "assistant" && e.message.stopReason === "error") sawError = true;
    if (e.type === "compaction") { if (!sawError) process.exit(2); sawCompaction = true; continue; }
    if (e.type === "message" && sawCompaction && e.message.role === "assistant" && e.message.stopReason === "stop") sawResumed = true;
  }
  process.exit(sawError && sawCompaction && sawResumed ? 0 : 1);
' "$(ls -t "$TMP/home-B"/.pi/agent/sessions/*/*.jsonl | head -1)" \
  || fail "scenario B: no resumed assistant response after error-triggered compaction"

printf 'OK: pi compaction auto-continue (completed-turn nudge + mid-turn-error resume)\n'
