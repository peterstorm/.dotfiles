#!/usr/bin/env bash
# Fail closed when a child ran but produced no final textual completion.
set -euo pipefail

(($# == 1)) || { echo "usage: $0 <run-dir>" >&2; exit 2; }
RUN_DIR="$(cd "$1" && pwd)"
SESSION="$RUN_DIR/session.jsonl"
OUT="$RUN_DIR/child-output-attestation.json"

[[ -r "$SESSION" ]] || {
  jq -n '{passed:false,checked_children:0,violations:["session.jsonl is missing"]}' > "$OUT"
  exit 1
}

node - "$SESSION" "$OUT" <<'NODE'
const fs = require("node:fs");
const [sessionPath, outputPath] = process.argv.slice(2);
const children = [];
const violations = [];
const textOf = (message) => Array.isArray(message?.content)
  ? message.content
      .filter((block) => block?.type === "text" && typeof block.text === "string")
      .map((block) => block.text)
      .join("")
      .trim()
  : "";
for (const [lineIndex, line] of fs.readFileSync(sessionPath, "utf8").split("\n").entries()) {
  if (line.trim() === "") continue;
  let event;
  try { event = JSON.parse(line); }
  catch { violations.push(`session line ${lineIndex + 1} is malformed JSON`); continue; }
  const message = event?.type === "message" ? event.message : undefined;
  if (message?.role !== "toolResult" || !["subagent", "loom_interactive_subagent"].includes(message.toolName)) continue;
  if (!Array.isArray(message.details?.results)) continue;
  for (const [resultIndex, result] of message.details.results.entries()) {
    if (!result || typeof result !== "object") continue;
    const ran = (Array.isArray(result.messages) && result.messages.length > 0) ||
      (typeof result.requestedModel === "string" && result.requestedModel.length > 0) ||
      (typeof result.usage?.turns === "number" && result.usage.turns > 0);
    if (!ran) continue;
    const label = `${message.toolName}:${result.agent ?? resultIndex}@line${lineIndex + 1}`;
    const assistants = Array.isArray(result.messages)
      ? result.messages.filter((entry) => entry?.role === "assistant")
      : [];
    const finalText = assistants.length > 0 ? textOf(assistants.at(-1)) : "";
    const explicitNoOutput = JSON.stringify(result).includes("(no output)");
    const passed = finalText.length > 0 && !explicitNoOutput && !result.errorMessage;
    children.push({ label, passed, final_text_bytes: Buffer.byteLength(finalText, "utf8") });
    if (!passed) violations.push(`${label} completed without final textual content`);
  }
}
const receipt = {
  passed: violations.length === 0,
  checked_children: children.length,
  children,
  violations,
};
fs.writeFileSync(outputPath, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
process.exit(receipt.passed ? 0 : 1);
NODE
