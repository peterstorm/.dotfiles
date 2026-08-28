#!/usr/bin/env bash
# Attest that every child process which actually ran used the benchmark arm's
# exact provider/model/thinking selector. Writes model-attestation.json and
# exits non-zero on missing evidence or any mixed-model child.
set -euo pipefail

(($# == 1)) || { echo "usage: $0 <run-dir>" >&2; exit 2; }
RUN_DIR="$(cd "$1" && pwd)"
RUN_JSON="$RUN_DIR/run.json"
SESSION_JSONL="$RUN_DIR/session.jsonl"
OUT="$RUN_DIR/model-attestation.json"

[[ -r "$RUN_JSON" ]] || { echo "missing benchmark run receipt: $RUN_JSON" >&2; exit 1; }
[[ -r "$SESSION_JSONL" ]] || {
  jq -n --arg expected "$(jq -r '.model // ""' "$RUN_JSON")" '{
    expected: $expected,
    checked_children: 0,
    passed: false,
    violations: ["session.jsonl is missing; child models cannot be attested"]
  }' >"$OUT"
  cat "$OUT"
  exit 1
}

node - "$RUN_JSON" "$SESSION_JSONL" "$OUT" <<'NODE'
const fs = require("node:fs");
const [runPath, sessionPath, outputPath] = process.argv.slice(2);
const run = JSON.parse(fs.readFileSync(runPath, "utf8"));
const expected = run.model;
const violations = [];
const children = [];

const exactSelector = (value) => typeof value === "string" && value.length > 0 ? value : null;
const selectorModelId = (selector) => {
  const slash = selector.indexOf("/");
  const modelWithThinking = slash >= 0 ? selector.slice(slash + 1) : selector;
  const thinking = /:(off|minimal|low|medium|high|xhigh|max)$/.exec(modelWithThinking);
  return thinking ? modelWithThinking.slice(0, -thinking[0].length) : modelWithThinking;
};
const actualMatches = (actual, effective) => {
  if (typeof actual !== "string" || actual.length === 0) return true;
  return actual === effective || actual === effective.replace(/:(off|minimal|low|medium|high|xhigh|max)$/, "") ||
    actual === selectorModelId(effective);
};

for (const [lineIndex, line] of fs.readFileSync(sessionPath, "utf8").split("\n").entries()) {
  if (line.trim() === "") continue;
  let event;
  try { event = JSON.parse(line); }
  catch { violations.push(`session line ${lineIndex + 1} is malformed JSON`); continue; }
  const message = event?.type === "message" ? event.message : undefined;
  if (message?.role !== "toolResult" || !["subagent", "loom_interactive_subagent"].includes(message.toolName)) continue;
  const results = message.details?.results;
  if (!Array.isArray(results)) continue;
  for (const [resultIndex, result] of results.entries()) {
    if (!result || typeof result !== "object") continue;
    const ran = (Array.isArray(result.messages) && result.messages.length > 0) ||
      (typeof result.requestedModel === "string" && result.requestedModel.length > 0) ||
      (typeof result.usage?.turns === "number" && result.usage.turns > 0);
    if (!ran) continue;
    const label = `${message.toolName}:${result.agent ?? resultIndex}@line${lineIndex + 1}`;
    const effective = exactSelector(result.routing?.effective);
    children.push({
      label,
      effective,
      requested_model: exactSelector(result.requestedModel),
      reported_model: exactSelector(result.model),
    });
    if (effective === null) {
      violations.push(`${label} ran without routing.effective evidence`);
      if (!actualMatches(result.model, expected)) {
        violations.push(`${label} reported model ${result.model}; expected ${expected}`);
      }
      continue;
    }
    if (effective !== expected) violations.push(`${label} routed to ${effective}; expected ${expected}`);
    if (result.requestedModel !== undefined && result.requestedModel !== effective) {
      violations.push(`${label} requested ${result.requestedModel}; routing receipt says ${effective}`);
    }
    if (!actualMatches(result.model, effective)) {
      violations.push(`${label} reported model ${result.model}; routed selector was ${effective}`);
    }
  }
}
const attestation = {
  expected,
  checked_children: children.length,
  passed: violations.length === 0,
  children,
  violations,
};
fs.writeFileSync(outputPath, `${JSON.stringify(attestation, null, 2)}\n`, { mode: 0o600 });
process.stdout.write(`${JSON.stringify(attestation, null, 2)}\n`);
process.exit(attestation.passed ? 0 : 1);
NODE
