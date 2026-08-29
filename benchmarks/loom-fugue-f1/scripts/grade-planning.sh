#!/usr/bin/env bash
# Mechanically grade Fugue F1 planning at the pending Wave 1 boundary.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(git -C "$BENCH_DIR" rev-parse --show-toplevel)"
# shellcheck source=benchmarks/loom-fugue-f1/suite.sh
source "$BENCH_DIR/suite.sh"
# shellcheck source=benchmarks/loom-model-ab/scripts/arms.sh
source "$ROOT/benchmarks/loom-model-ab/scripts/arms.sh"

(($# == 2)) || { echo "usage: $0 <worktree> <run-dir>" >&2; exit 2; }
WORKTREE="$(cd "$1" && pwd)"
mkdir -p "$2"
RUN_DIR="$(cd "$2" && pwd)"
RUN_RECEIPT="$RUN_DIR/run.json"
GRAPH_SOURCE="$WORKTREE/.claude/state/active_task_graph.json"
[[ -r "$RUN_DIR/base_sha" && -r "$RUN_RECEIPT" ]] || { echo 'missing base_sha or run.json' >&2; exit 1; }

BASE_SHA="$(<"$RUN_DIR/base_sha")"
TARGET_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.target.base_sha')"
TARGET_REPOSITORY="$(fugue_source_lock_value "$BENCH_DIR" '.target.repository')"
RUNTIME_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.loom_runtime.base_sha')"
EXPECTED_PI="$(fugue_source_lock_value "$BENCH_DIR" '.pi.version')"
PROTOCOL_SHA="$(fugue_protocol_sha "$BENCH_DIR")"
PI_MODELS_SHA="$(sha256sum "$ROOT/pi/models.json" | cut -d' ' -f1)"
RUN_ARM="$(jq -r '.arm // ""' "$RUN_RECEIPT" 2>/dev/null || true)"
ARM_RECORD="$(fugue_benchmark_arm_record "$RUN_ARM" 2>/dev/null || true)"
IFS=$'\t' read -r EXPECTED_MODEL EXPECTED_SERVED EXPECTED_CONTEXT EXPECTED_PROFILE _ <<<"$ARM_RECORD"

json_bool() { [[ "$1" == true ]] && echo true || echo false; }
artifact_present() { [[ -s "$RUN_DIR/$1" ]] && echo true || echo false; }

RUN_RECEIPT_VALID=false
if [[ "$BASE_SHA" == "$TARGET_SHA" && -n "$ARM_RECORD" ]] && jq -e \
  --arg suite "$FUGUE_SUITE_ID" \
  --arg version "$FUGUE_PROTOCOL_VERSION" \
  --arg protocol "$PROTOCOL_SHA" \
  --arg target "$TARGET_SHA" \
  --arg repository "$TARGET_REPOSITORY" \
  --arg runtime "$RUNTIME_SHA" \
  --arg pi "$EXPECTED_PI" \
  --arg model "$EXPECTED_MODEL" \
  --arg served "$EXPECTED_SERVED" \
  --arg profile "$EXPECTED_PROFILE" \
  --argjson context "$EXPECTED_CONTEXT" \
  --arg pi_models_sha "$PI_MODELS_SHA" '
    .benchmark_kind == "planning-only" and
    .suite_id == $suite and
    .protocol_version == $version and
    .protocol_sha256 == $protocol and
    .stop_before == "wave-1-implementation" and
    .target == {repository: $repository, base_sha: $target} and
    .loom_runtime_sha == $runtime and
    .pi_version == $pi and
    .model == $model and
    .served_model == $served and
    .profile_container == $profile and
    .context_window == $context and
    .pi_models_sha256 == $pi_models_sha and
    (.image_config | test("^sha256:[0-9a-f]{64}$")) and
    .baseline_typecheck == "clean"
  ' "$RUN_RECEIPT" >/dev/null 2>&1; then
  RUN_RECEIPT_VALID=true
fi

TARGET_BASE_EXACT=false
if [[ "$(git -C "$WORKTREE" rev-parse "$BASE_SHA^{commit}" 2>/dev/null || true)" == "$TARGET_SHA" ]]; then
  TARGET_BASE_EXACT=true
fi

capture_graph_artifact() {
  local graph_key="$1" destination="$2" candidate unresolved resolved
  candidate="$(jq -er "$graph_key | select(type == \"string\" and length > 0)" "$GRAPH_SOURCE" 2>/dev/null)" || return 1
  case "$candidate" in
    /*) unresolved="$candidate" ;;
    *) unresolved="$WORKTREE/$candidate" ;;
  esac
  resolved="$(realpath -e "$unresolved" 2>/dev/null)" || return 1
  [[ "$resolved" == "$WORKTREE/"* ]] || return 1
  cp "$resolved" "$RUN_DIR/$destination"
}

if [[ -r "$GRAPH_SOURCE" ]]; then
  cp "$GRAPH_SOURCE" "$RUN_DIR/task-graph.json"
  capture_graph_artifact '.spec_file' spec.md || true
  capture_graph_artifact '.plan_file' plan.md || true
  SPEC_DIR="$(jq -er '.spec_dir | select(type == "string" and length > 0)' "$GRAPH_SOURCE" 2>/dev/null || true)"
  if [[ -n "$SPEC_DIR" ]]; then
    for artifact in brainstorm.md plan-alignment.md; do
      candidate="$(realpath -e "$WORKTREE/$SPEC_DIR/$artifact" 2>/dev/null || true)"
      if [[ -n "$candidate" && "$candidate" == "$WORKTREE/"* ]]; then cp "$candidate" "$RUN_DIR/$artifact"; fi
    done
  fi
fi

git -C "$WORKTREE" add -A -- . \
  ':(exclude)node_modules' \
  ':(exclude)packages/framework/node_modules' >/dev/null 2>&1 || true
mapfile -t CHANGED < <(git -C "$WORKTREE" diff --cached --name-only "$BASE_SHA" -- || true)
printf '%s\n' "${CHANGED[@]}" > "$RUN_DIR/changed-files.txt"
git -C "$WORKTREE" diff --cached "$BASE_SHA" -- > "$RUN_DIR/diff.patch" || true

PLANNING_SCOPE_RESPECTED=true
IMPLEMENTATION_STARTED=false
for file in "${CHANGED[@]}"; do
  [[ -z "$file" ]] && continue
  case "$file" in
    .claude/*) ;;
    *)
      printf 'non-planning change: %s\n' "$file" >&2
      PLANNING_SCOPE_RESPECTED=false
      IMPLEMENTATION_STARTED=true
      ;;
  esac
done

GRAPH_AT_BOUNDARY=false
if [[ -r "$RUN_DIR/task-graph.json" ]] && jq -e '
  .current_phase == "execute" and
  .current_wave == 1 and
  (.tasks | type == "array" and length > 0 and all(.status == "pending")) and
  ((.executing_tasks // []) | type == "array" and length == 0) and
  (.wave_gates | type == "object" and length > 0 and ([.[]] | all(
    .impl_complete == false and .reviews_complete == false and .tests_passed == null
  )))
' "$RUN_DIR/task-graph.json" >/dev/null 2>&1; then
  GRAPH_AT_BOUNDARY=true
fi

BRAINSTORM_PRESENT="$(artifact_present brainstorm.md)"
SPEC_PRESENT="$(artifact_present spec.md)"
PLAN_PRESENT="$(artifact_present plan.md)"
ALIGNMENT_PRESENT="$(artifact_present plan-alignment.md)"
GRAPH_PRESENT="$(artifact_present task-graph.json)"
INTERVIEW_PRESENT="$(artifact_present interview.md)"
SESSION_PRESENT="$(artifact_present session.jsonl)"
DRIVER_RECEIPT_PRESENT="$(artifact_present driver-receipt.json)"

DRIVER_PASS=false
if [[ "$DRIVER_RECEIPT_PRESENT" == true ]] && jq -e '
  .passed == true and .abort_sent == true and .session_copied == true and
  (.boundary_at | type == "string" and length > 0) and .protocol_error == null
' "$RUN_DIR/driver-receipt.json" >/dev/null 2>&1; then DRIVER_PASS=true; fi

TASK_IDENTITY_PRESENT=false
if [[ "$SPEC_PRESENT" == true && "$PLAN_PRESENT" == true ]] &&
   grep -Eiq 'runtime[- ]width|scatter[-/ ]gather|map (node|instance)|dynamic fan[- ]out' "$RUN_DIR/spec.md" &&
   grep -Eiq 'runtime[- ]width|scatter[-/ ]gather|map (node|instance)|dynamic fan[- ]out' "$RUN_DIR/plan.md"; then
  TASK_IDENTITY_PRESENT=true
fi

CROSS_RUN_CONTAMINATED=false
if [[ "$SESSION_PRESENT" == true ]] && grep -Eiq \
  'CORTEX_MEMORY_START|CORTEX_RECALL_START|/dev/notes/remotevault|claude-plugins/obsidian|obsidian-vault|loom-fugue-f1/(hidden|frozen)|hidden/(reference-spec|acceptance-scenarios)' \
  "$RUN_DIR/session.jsonl"; then CROSS_RUN_CONTAMINATED=true; fi

EXTERNAL_SIDE_EFFECT=false
if [[ "$SESSION_PRESENT" == true ]]; then
  if ! node - "$RUN_DIR/session.jsonl" "$RUN_DIR/side-effect-attestation.json" "$WORKTREE" <<'NODE'
const fs = require("node:fs");
const [sessionPath, outputPath, worktree] = process.argv.slice(2);
const violations = [];
const visit = (value) => {
  if (Array.isArray(value)) { value.forEach(visit); return; }
  if (!value || typeof value !== "object") return;
  if (value.type === "toolCall" && value.arguments && typeof value.arguments === "object") {
    const args = JSON.stringify(value.arguments);
    const toolName = typeof value.name === "string" ? value.name : "";
    const candidatePath = typeof value.arguments.path === "string" ? value.arguments.path : "";
    if (/\bgh\s+issue\s+create\b|\bgit\s+push\b|\bscp\b|\brsync\b/i.test(args)) violations.push(args);
    if (/(github|gh)/i.test(toolName) && /(create|write).*(issue|pull)|issue.*(create|write)/i.test(args)) violations.push(args);
    if (["write", "edit"].includes(toolName) && candidatePath.startsWith("/") && !candidatePath.startsWith(`${worktree}/`)) violations.push(args);
    if (/dev\/notes\/remotevault|loom-fugue-f1\/(hidden|frozen)|hidden\/(reference-spec|acceptance-scenarios)/i.test(args)) violations.push(args);
  }
  Object.values(value).forEach(visit);
};
for (const line of fs.readFileSync(sessionPath, "utf8").split("\n")) {
  if (!line.trim()) continue;
  try { visit(JSON.parse(line)); } catch { violations.push("malformed session JSON"); }
}
fs.writeFileSync(outputPath, `${JSON.stringify({ passed: violations.length === 0, violations }, null, 2)}\n`);
process.exit(violations.length === 0 ? 0 : 1);
NODE
  then
    EXTERNAL_SIDE_EFFECT=true
  fi
else
  printf '%s\n' '{"passed":false,"violations":["session missing"]}' > "$RUN_DIR/side-effect-attestation.json"
fi

MODEL_ATTESTATION_PASS=false
if bash "$ROOT/benchmarks/loom-model-ab/scripts/verify-run-models.sh" "$RUN_DIR" >/dev/null 2>&1 &&
   jq -e '.passed == true and .checked_children > 0' "$RUN_DIR/model-attestation.json" >/dev/null; then
  MODEL_ATTESTATION_PASS=true
fi
MODEL_ATTESTATION_JSON="$(cat "$RUN_DIR/model-attestation.json")"

CHILD_OUTPUTS_PASS=false
if bash "$BENCH_DIR/scripts/verify-child-outputs.sh" "$RUN_DIR" >/dev/null 2>&1 &&
   jq -e '.passed == true and .checked_children > 0' "$RUN_DIR/child-output-attestation.json" >/dev/null; then
  CHILD_OUTPUTS_PASS=true
fi
CHILD_OUTPUT_JSON="$(cat "$RUN_DIR/child-output-attestation.json")"

FORBIDDEN_EXECUTION_CHILD=false
if jq -e '[.children[]?.label] | any(test("implementer|test-agent|reviewer|wave[-_]?gate|adr-writer"; "i"))' \
  "$RUN_DIR/model-attestation.json" >/dev/null 2>&1; then FORBIDDEN_EXECUTION_CHILD=true; fi

if [[ ! -e "$RUN_DIR/discovery-checklist.tsv" ]]; then
  node - "$BENCH_DIR/hidden/reference-spec.md" "$RUN_DIR/discovery-checklist.tsv" <<'NODE'
const fs = require("node:fs");
const [referencePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(referencePath, "utf8");
const rows = [["requirement", "reference", "spec_discovered", "plan_accounted", "task_graph_accounted", "notes"]];
for (const match of source.matchAll(/^- \*\*(FR-\d+)\*\* ([\s\S]*?)(?=\n- \*\*FR-|\n## |$)/gm)) {
  rows.push([match[1], match[2].replace(/\s+/g, " ").trim(), "UNSCORED", "UNSCORED", "UNSCORED", ""]);
}
const escape = (value) => /[\t\n"]/.test(value) ? `"${value.replaceAll('"', '""')}"` : value;
fs.writeFileSync(outputPath, `${rows.map((row) => row.map(escape).join("\t")).join("\n")}\n`);
NODE
fi

PLANNING_COMPLETE=false
if [[ "$RUN_RECEIPT_VALID" == true && "$TARGET_BASE_EXACT" == true &&
      "$PLANNING_SCOPE_RESPECTED" == true && "$IMPLEMENTATION_STARTED" == false &&
      "$GRAPH_AT_BOUNDARY" == true && "$BRAINSTORM_PRESENT" == true &&
      "$SPEC_PRESENT" == true && "$PLAN_PRESENT" == true && "$ALIGNMENT_PRESENT" == true &&
      "$GRAPH_PRESENT" == true && "$INTERVIEW_PRESENT" == true && "$SESSION_PRESENT" == true &&
      "$DRIVER_PASS" == true && "$TASK_IDENTITY_PRESENT" == true &&
      "$CROSS_RUN_CONTAMINATED" == false && "$EXTERNAL_SIDE_EFFECT" == false &&
      "$MODEL_ATTESTATION_PASS" == true && "$CHILD_OUTPUTS_PASS" == true &&
      "$FORBIDDEN_EXECUTION_CHILD" == false ]]; then PLANNING_COMPLETE=true; fi

jq -n \
  --arg worktree "$WORKTREE" \
  --arg base_sha "$BASE_SHA" \
  --arg suite_id "$FUGUE_SUITE_ID" \
  --arg protocol_version "$FUGUE_PROTOCOL_VERSION" \
  --arg protocol_sha256 "$PROTOCOL_SHA" \
  --argjson planning_only_receipt "$(json_bool "$RUN_RECEIPT_VALID")" \
  --argjson target_base_exact "$(json_bool "$TARGET_BASE_EXACT")" \
  --argjson planning_scope_respected "$(json_bool "$PLANNING_SCOPE_RESPECTED")" \
  --argjson implementation_started "$(json_bool "$IMPLEMENTATION_STARTED")" \
  --argjson task_graph_at_execution_boundary "$(json_bool "$GRAPH_AT_BOUNDARY")" \
  --argjson rpc_driver_passed "$(json_bool "$DRIVER_PASS")" \
  --argjson task_identity_present "$(json_bool "$TASK_IDENTITY_PRESENT")" \
  --argjson cross_run_contaminated "$(json_bool "$CROSS_RUN_CONTAMINATED")" \
  --argjson external_side_effect "$(json_bool "$EXTERNAL_SIDE_EFFECT")" \
  --argjson child_models_attested "$(json_bool "$MODEL_ATTESTATION_PASS")" \
  --argjson child_outputs_attested "$(json_bool "$CHILD_OUTPUTS_PASS")" \
  --argjson forbidden_execution_child "$(json_bool "$FORBIDDEN_EXECUTION_CHILD")" \
  --argjson model_attestation "$MODEL_ATTESTATION_JSON" \
  --argjson child_output_attestation "$CHILD_OUTPUT_JSON" \
  --argjson brainstorm "$BRAINSTORM_PRESENT" \
  --argjson spec "$SPEC_PRESENT" \
  --argjson plan "$PLAN_PRESENT" \
  --argjson plan_alignment "$ALIGNMENT_PRESENT" \
  --argjson task_graph "$GRAPH_PRESENT" \
  --argjson interview "$INTERVIEW_PRESENT" \
  --argjson session "$SESSION_PRESENT" \
  --argjson driver_receipt "$DRIVER_RECEIPT_PRESENT" \
  --argjson planning_complete "$(json_bool "$PLANNING_COMPLETE")" '
  {
    worktree: $worktree,
    base_sha: $base_sha,
    suite_id: $suite_id,
    protocol_version: $protocol_version,
    protocol_sha256: $protocol_sha256,
    protocol: {
      planning_only_receipt: $planning_only_receipt,
      target_base_exact: $target_base_exact,
      planning_scope_respected: $planning_scope_respected,
      implementation_started: $implementation_started,
      task_graph_at_execution_boundary: $task_graph_at_execution_boundary,
      rpc_driver_passed: $rpc_driver_passed,
      task_identity_present: $task_identity_present,
      cross_run_contaminated: $cross_run_contaminated,
      external_side_effect: $external_side_effect,
      child_models_attested: $child_models_attested,
      child_outputs_attested: $child_outputs_attested,
      forbidden_execution_child: $forbidden_execution_child,
      model_attestation: $model_attestation,
      child_output_attestation: $child_output_attestation
    },
    artifacts: {
      brainstorm: $brainstorm,
      spec: $spec,
      plan: $plan,
      plan_alignment: $plan_alignment,
      task_graph: $task_graph,
      interview: $interview,
      session: $session,
      driver_receipt: $driver_receipt
    },
    discovery_checklist: "discovery-checklist.tsv",
    planning_complete: $planning_complete
  }' > "$RUN_DIR/outcome.planning.json"

cat "$RUN_DIR/outcome.planning.json"
echo
echo 'Semantic grading: complete discovery-checklist.tsv, then use hidden/reference-spec.md, hidden/acceptance-scenarios.md, and rubric.md.'
[[ "$PLANNING_COMPLETE" == true ]]
