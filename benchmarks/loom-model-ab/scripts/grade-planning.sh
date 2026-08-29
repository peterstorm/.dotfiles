#!/usr/bin/env bash
# Mechanically grade a planning-only benchmark run at the decompose/execute seam.
#
#   bash scripts/grade-planning.sh <worktree> <run-dir>
#
# The valid terminal state is: specification, architecture, alignment, and task
# decomposition are complete; every task is still pending; no implementation
# file has changed. Semantic plan quality is scored separately with rubric.md.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(($# == 2)) || { echo "usage: $0 <worktree> <run-dir>" >&2; exit 2; }
WORKTREE="$(cd "$1" && pwd)"
mkdir -p "$2"
RUN_DIR="$(cd "$2" && pwd)"

[[ -r "$RUN_DIR/base_sha" ]] || {
  echo "missing $RUN_DIR/base_sha — created by run-arm.sh; refusing to guess the baseline" >&2
  exit 1
}
BASE_SHA="$(<"$RUN_DIR/base_sha")"
GRAPH_SOURCE="$WORKTREE/.claude/state/active_task_graph.json"
RUN_RECEIPT="$RUN_DIR/run.json"

RUN_RECEIPT_VALID=false
if jq -e '
  .benchmark_kind == "planning-only" and
  .stop_before == "wave-1-implementation"
' "$RUN_RECEIPT" >/dev/null 2>&1; then
  RUN_RECEIPT_VALID=true
fi

json_bool() { [[ "$1" == true ]] && echo true || echo false; }

# Model-authored paths in the graph are untrusted. Resolve each artifact and
# refuse to copy anything outside the isolated worktree.
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

# Capture the planning artifacts before staging the worktree for scope analysis.
if [[ -r "$GRAPH_SOURCE" ]]; then
  cp "$GRAPH_SOURCE" "$RUN_DIR/task-graph.json"
  capture_graph_artifact '.spec_file' spec.md || true
  capture_graph_artifact '.plan_file' plan.md || true

  SPEC_DIR="$(jq -er '.spec_dir | select(type == "string" and length > 0)' "$GRAPH_SOURCE" 2>/dev/null || true)"
  if [[ -n "$SPEC_DIR" ]]; then
    for artifact in brainstorm.md plan-alignment.md; do
      candidate="$(realpath -e "$WORKTREE/$SPEC_DIR/$artifact" 2>/dev/null || true)"
      if [[ -n "$candidate" && "$candidate" == "$WORKTREE/"* ]]; then
        cp "$candidate" "$RUN_DIR/$artifact"
      fi
    done
  fi
fi

# Everything after the frozen-types commit is model work. Staging is safe in
# this disposable worktree and includes untracked planning artifacts.
git -C "$WORKTREE" add -A >/dev/null 2>&1 || true
mapfile -t CHANGED < <(git -C "$WORKTREE" diff --cached --name-only "$BASE_SHA" -- || true)
printf '%s\n' "${CHANGED[@]}" > "$RUN_DIR/changed-files.txt"
git -C "$WORKTREE" diff --cached "$BASE_SHA" > "$RUN_DIR/diff.patch" || true

FROZEN_INTACT=false
if cmp -s "$BENCH_DIR/frozen/ui-relay-types.ts" "$WORKTREE/engine/src/core/ui-relay-types.ts"; then
  FROZEN_INTACT=true
else
  diff -u "$BENCH_DIR/frozen/ui-relay-types.ts" "$WORKTREE/engine/src/core/ui-relay-types.ts" \
    > "$RUN_DIR/frozen-file.diff" || true
fi

PLANNING_SCOPE_RESPECTED=true
IMPLEMENTATION_STARTED=false
for file in "${CHANGED[@]}"; do
  [[ -z "$file" ]] && continue
  case "$file" in
    .claude/*|node_modules) ;;
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
  (.wave_gates | (
    type == "object" and
    length > 0 and
    ([.[]] | all(
      .impl_complete == false and
      .reviews_complete == false and
      .tests_passed == null
    ))
  ))
' "$RUN_DIR/task-graph.json" >/dev/null 2>&1; then
  GRAPH_AT_BOUNDARY=true
fi

artifact_present() { [[ -s "$RUN_DIR/$1" ]] && echo true || echo false; }
BRAINSTORM_PRESENT="$(artifact_present brainstorm.md)"
SPEC_PRESENT="$(artifact_present spec.md)"
PLAN_PRESENT="$(artifact_present plan.md)"
ALIGNMENT_PRESENT="$(artifact_present plan-alignment.md)"
GRAPH_PRESENT="$(artifact_present task-graph.json)"
INTERVIEW_PRESENT="$(artifact_present interview.md)"
SESSION_PRESENT="$(artifact_present session.jsonl)"

CORTEX_CONTAMINATED=false
if [[ "$SESSION_PRESENT" == true ]] && grep -Fq 'CORTEX_MEMORY_START' "$RUN_DIR/session.jsonl"; then
  CORTEX_CONTAMINATED=true
fi

MODEL_ATTESTATION_PASS=false
if bash "$BENCH_DIR/scripts/verify-run-models.sh" "$RUN_DIR" >/dev/null; then
  if jq -e '.passed == true and .checked_children > 0' "$RUN_DIR/model-attestation.json" >/dev/null; then
    MODEL_ATTESTATION_PASS=true
  fi
fi
MODEL_ATTESTATION_JSON="$(cat "$RUN_DIR/model-attestation.json")"

FORBIDDEN_EXECUTION_CHILD=false
if jq -e '
  [.children[]?.label] | any(test(
    "implementer|test-agent|reviewer|wave[-_]gate|adr-writer";
    "i"
  ))
' "$RUN_DIR/model-attestation.json" >/dev/null 2>&1; then
  FORBIDDEN_EXECUTION_CHILD=true
fi

# This worksheet is intentionally semantic and human-scored. Generate it once;
# never overwrite a grader's completed decisions on a re-run.
if [[ ! -e "$RUN_DIR/discovery-checklist.tsv" ]]; then
  node - "$BENCH_DIR/hidden/reference-spec.md" "$RUN_DIR/discovery-checklist.tsv" <<'NODE'
const fs = require("node:fs");
const [referencePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(referencePath, "utf8");
const rows = [["requirement", "reference", "spec_discovered", "plan_accounted", "task_graph_accounted", "notes"]];
for (const match of source.matchAll(/^- \*\*(FR-\d+)\*\* ([\s\S]*?)(?=\n- \*\*FR-|\n## |$)/gm)) {
  const text = match[2].replace(/\s+/g, " ").trim();
  rows.push([match[1], text, "UNSCORED", "UNSCORED", "UNSCORED", ""]);
}
const escape = (value) => value.includes("\t") || value.includes("\n") || value.includes('"')
  ? `"${value.replaceAll('"', '""')}"`
  : value;
fs.writeFileSync(outputPath, `${rows.map((row) => row.map(escape).join("\t")).join("\n")}\n`);
NODE
fi

PLANNING_COMPLETE=false
if [[ "$RUN_RECEIPT_VALID" == true &&
      "$FROZEN_INTACT" == true &&
      "$PLANNING_SCOPE_RESPECTED" == true &&
      "$IMPLEMENTATION_STARTED" == false &&
      "$GRAPH_AT_BOUNDARY" == true &&
      "$BRAINSTORM_PRESENT" == true &&
      "$SPEC_PRESENT" == true &&
      "$PLAN_PRESENT" == true &&
      "$ALIGNMENT_PRESENT" == true &&
      "$GRAPH_PRESENT" == true &&
      "$INTERVIEW_PRESENT" == true &&
      "$SESSION_PRESENT" == true &&
      "$CORTEX_CONTAMINATED" == false &&
      "$MODEL_ATTESTATION_PASS" == true &&
      "$FORBIDDEN_EXECUTION_CHILD" == false ]]; then
  PLANNING_COMPLETE=true
fi

jq -n \
  --arg worktree "$WORKTREE" \
  --arg base_sha "$BASE_SHA" \
  --argjson planning_only_receipt "$(json_bool "$RUN_RECEIPT_VALID")" \
  --argjson frozen_file_intact "$(json_bool "$FROZEN_INTACT")" \
  --argjson planning_scope_respected "$(json_bool "$PLANNING_SCOPE_RESPECTED")" \
  --argjson implementation_started "$(json_bool "$IMPLEMENTATION_STARTED")" \
  --argjson task_graph_at_execution_boundary "$(json_bool "$GRAPH_AT_BOUNDARY")" \
  --argjson brainstorm "$BRAINSTORM_PRESENT" \
  --argjson spec "$SPEC_PRESENT" \
  --argjson plan "$PLAN_PRESENT" \
  --argjson plan_alignment "$ALIGNMENT_PRESENT" \
  --argjson task_graph "$GRAPH_PRESENT" \
  --argjson interview "$INTERVIEW_PRESENT" \
  --argjson session "$SESSION_PRESENT" \
  --argjson cortex_contaminated "$(json_bool "$CORTEX_CONTAMINATED")" \
  --argjson child_models_attested "$(json_bool "$MODEL_ATTESTATION_PASS")" \
  --argjson forbidden_execution_child "$(json_bool "$FORBIDDEN_EXECUTION_CHILD")" \
  --argjson model_attestation "$MODEL_ATTESTATION_JSON" \
  --argjson planning_complete "$(json_bool "$PLANNING_COMPLETE")" \
  '{
    worktree: $worktree,
    base_sha: $base_sha,
    protocol: {
      planning_only_receipt: $planning_only_receipt,
      frozen_file_intact: $frozen_file_intact,
      planning_scope_respected: $planning_scope_respected,
      implementation_started: $implementation_started,
      task_graph_at_execution_boundary: $task_graph_at_execution_boundary,
      cortex_contaminated: $cortex_contaminated,
      child_models_attested: $child_models_attested,
      forbidden_execution_child: $forbidden_execution_child,
      model_attestation: $model_attestation
    },
    artifacts: {
      brainstorm: $brainstorm,
      spec: $spec,
      plan: $plan,
      plan_alignment: $plan_alignment,
      task_graph: $task_graph,
      interview: $interview,
      session: $session
    },
    discovery_checklist: "discovery-checklist.tsv",
    planning_complete: $planning_complete
  }' > "$RUN_DIR/outcome.planning.json"

cat "$RUN_DIR/outcome.planning.json"
echo
echo "Semantic grading still required:"
echo "  * complete discovery-checklist.tsv against hidden/reference-spec.md"
echo "  * score anonymised artifacts with rubric.md"

[[ "$PLANNING_COMPLETE" == true ]]
