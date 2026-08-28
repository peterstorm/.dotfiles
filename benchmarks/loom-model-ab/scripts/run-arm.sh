#!/usr/bin/env bash
# Prepare one planning-only benchmark arm: isolated worktree, frozen contract,
# and recorded baseline. Stops short of launching Pi because the model conducts
# its own interview. The model must stop after decomposition, before Wave 1.
#
#   bash scripts/run-arm.sh --list
#   bash scripts/run-arm.sh --probe glm-mtp
#   bash scripts/run-arm.sh glm-mtp 1
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOM="${LOOM_REPO:-$HOME/dev/claude-plugins/loom}"
# shellcheck source=benchmarks/loom-model-ab/scripts/arms.sh
source "$BENCH_DIR/scripts/arms.sh"

usage() {
  echo "usage: $0 --list | --probe <arm> | <arm> <repetition>" >&2
}

if (($# == 1)) && [[ "$1" == --list ]]; then
  printf '%-12s %-58s %-42s %s\n' ARM PI_MODEL SERVED_MODEL CONTEXT
  while IFS= read -r listed_arm; do
    IFS=$'\t' read -r listed_model listed_served listed_context _ \
      <<<"$(benchmark_arm_record "$listed_arm")"
    printf '%-12s %-58s %-42s %s\n' \
      "$listed_arm" "$listed_model" "$listed_served" "$listed_context"
  done < <(benchmark_arm_ids)
  exit 0
fi

PROBE_ONLY=false
if (($# == 2)) && [[ "$1" == --probe ]]; then
  PROBE_ONLY=true
  ARM="$2"
  REP=0
elif (($# == 2)); then
  ARM="$1"
  REP="$2"
else
  usage
  exit 2
fi

ARM_RECORD="$(benchmark_arm_record "$ARM")" || exit $?
IFS=$'\t' read -r MODEL EXPECTED CONTEXT_WINDOW PROFILE_CONTAINER START_HINT PROFILE_LABEL \
  <<<"$ARM_RECORD"
[[ "$REP" =~ ^[0-9]+$ ]] || { echo "repetition must be an integer" >&2; exit 2; }

BASE_SHA="$(git -C "$LOOM" rev-parse HEAD)"
BASELINE_FILE="$BENCH_DIR/baseline/known-failures.json"
[[ -f "$BASELINE_FILE" ]] || {
  echo "missing benchmark baseline; run: bash $BENCH_DIR/scripts/baseline.sh" >&2
  exit 1
}
BASELINE_SHA="$(jq -er '.base_sha' "$BASELINE_FILE")" || {
  echo "invalid benchmark baseline: $BASELINE_FILE" >&2
  exit 1
}
[[ "$BASELINE_SHA" == "$BASE_SHA" ]] || {
  echo "stale benchmark baseline: recorded $BASELINE_SHA, Loom is $BASE_SHA" >&2
  echo "refresh it before running an arm: bash $BENCH_DIR/scripts/baseline.sh" >&2
  exit 1
}

PI_SETTINGS="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json"
[[ -f "$PI_SETTINGS" ]] || { echo "missing Pi settings: $PI_SETTINGS" >&2; exit 1; }
if node -e '
  const settings = require(process.argv[1]);
  process.exit((settings.packages ?? []).some((entry) => entry.includes("cortex")) ? 0 : 1);
' "$PI_SETTINGS"; then
  echo "Cortex is active; cross-arm memory would contaminate this run." >&2
  echo "Disable it first: bash $BENCH_DIR/scripts/isolation.sh off" >&2
  exit 1
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$ARM-$REP"
RUN_DIR="$BENCH_DIR/runs/$RUN_ID"
WORKTREE="$LOOM/../loom-bench-$RUN_ID"

# --- the backend must actually be serving the arm's model -------------------
#
# Health alone has lied during a cutover before, so this asks for an
# authenticated model list and checks the served name. Starting a run against
# the other arm's container is the one mistake that silently invalidates
# everything downstream.

# Same resolution chain as pi/models.json, including the ssh fallback — on a
# machine that is not the desktop, the key exists only on the desktop.
resolve_key() {
  local candidate
  for candidate in ~/.config/ds4-flash/api-key ~/.config/qwen38/api-key \
                   ~/.config/glm53/api-key ~/.config/muse-glimmer/api-key \
                   ~/.config/sops-nix/secrets/vllm-api-key; do
    [[ -r "$candidate" ]] && { cat "$candidate"; return 0; }
  done
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${INFERENCE_HOST:-desktop}" '
    for candidate in ~/.config/ds4-flash/api-key ~/.config/qwen38/api-key \
      ~/.config/glm53/api-key ~/.config/muse-glimmer/api-key; do
      [ -r "$candidate" ] && { cat "$candidate"; exit 0; }
    done
    exit 1
  ' 2>/dev/null
}

API_KEY="$(resolve_key)"
[[ -n "$API_KEY" ]] || { echo "could not resolve an inference api-key locally or from the desktop" >&2; exit 1; }
ESCAPED_API_KEY="${API_KEY//\\/\\\\}"
ESCAPED_API_KEY="${ESCAPED_API_KEY//\"/\\\"}"

# Read the credential through curl's stdin config so it never appears in argv.
MODELS_JSON="$({
  printf 'header = "Authorization: Bearer %s"\n' "$ESCAPED_API_KEY"
} | curl --config - -fsS -m 15 \
  "${INFERENCE_URL:-http://192.168.0.80:8000}/v1/models" 2>/dev/null)" || MODELS_JSON=''
SERVED="$(jq -er '
  .data | select(type == "array" and length == 1) | .[0].id | select(type == "string")
' <<<"$MODELS_JSON" 2>/dev/null)" || SERVED=''
unset API_KEY ESCAPED_API_KEY MODELS_JSON

if [[ "$SERVED" != "$EXPECTED" ]]; then
  cat >&2 <<EOF
Backend mismatch: :8000 is serving '${SERVED:-<nothing or multiple models>}', arm '$ARM' needs '$EXPECTED'.

Attended startup hint for $PROFILE_LABEL:
  $START_HINT

Wait for an authenticated /v1/models before retrying — a cold start takes minutes.
EOF
  exit 1
fi

if [[ "$PROBE_ONLY" == true ]]; then
  printf 'READY: arm=%s model=%s served=%s context=%s profile=%s baseline=%s\n' \
    "$ARM" "$MODEL" "$SERVED" "$CONTEXT_WINDOW" "$PROFILE_CONTAINER" "$BASE_SHA"
  exit 0
fi

# --- isolated worktree off a recorded baseline ------------------------------

git -C "$LOOM" worktree add "$WORKTREE" -b "bench/$RUN_ID" "$BASE_SHA"
WORKTREE="$(cd "$WORKTREE" && pwd)"

# A fresh worktree has engine/node_modules (tracked) but not the root one, and
# without it pi's peer-dep types resolve to `any` — `tsc --noEmit` then fails at
# baseline on files nobody touched. Left unfixed, every arm scores
# typecheck_clean:false whatever it writes, and the instrument measures nothing.
if [[ ! -e "$WORKTREE/node_modules" && -d "$LOOM/node_modules" ]]; then
  ln -s "$LOOM/node_modules" "$WORKTREE/node_modules"
fi

cp "$BENCH_DIR/frozen/ui-relay-types.ts" "$WORKTREE/engine/src/core/ui-relay-types.ts"
git -C "$WORKTREE" add engine/src/core/ui-relay-types.ts
git -C "$WORKTREE" -c user.name=benchmark -c user.email=bench@local \
  commit -qm "bench: frozen wave-0 types artifact"

mkdir -p "$RUN_DIR"
git -C "$WORKTREE" rev-parse HEAD > "$RUN_DIR/base_sha"

# Baseline evidence, captured before the model touches anything. A grade that
# cannot distinguish "this arm broke the typecheck" from "the typecheck was
# already broken" is not evidence.
(cd "$WORKTREE/engine" && env -u PI_CODING_AGENT timeout 300 bunx tsc --noEmit) \
  > "$RUN_DIR/baseline-typecheck.log" 2>&1 && BASELINE_TSC=clean || BASELINE_TSC=dirty
echo "baseline typecheck: $BASELINE_TSC"
if [[ "$BASELINE_TSC" == dirty ]]; then
  echo "error: frozen worktree does not typecheck; SC-001 is unreachable" >&2
  echo "preserving $WORKTREE and $RUN_DIR for diagnosis" >&2
  exit 1
fi
mapfile -t PROTOCOL_FILES < <(benchmark_protocol_files)
(
  cd "$BENCH_DIR"
  sha256sum "${PROTOCOL_FILES[@]}"
) > "$RUN_DIR/protocol.sha256"
PROTOCOL_SHA="$(sha256sum "$RUN_DIR/protocol.sha256" | cut -d' ' -f1)"
BENCHMARK_COMMIT="$(git -C "$BENCH_DIR" rev-parse HEAD)"
PI_VERSION="$(pi --version 2>/dev/null || printf unknown)"
STARTED="$(date -Is)"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg arm "$ARM" \
  --argjson repetition "$REP" \
  --arg model "$MODEL" \
  --arg served_model "$SERVED" \
  --arg profile_container "$PROFILE_CONTAINER" \
  --argjson context_window "$CONTEXT_WINDOW" \
  --arg loom_base_sha "$BASE_SHA" \
  --arg benchmark_commit "$BENCHMARK_COMMIT" \
  --arg protocol_sha256 "$PROTOCOL_SHA" \
  --arg pi_version "$PI_VERSION" \
  --arg worktree "$WORKTREE" \
  --arg baseline_typecheck "$BASELINE_TSC" \
  --arg started "$STARTED" \
  '{
    benchmark_kind: "planning-only",
    stop_before: "wave-1-implementation",
    run_id: $run_id,
    arm: $arm,
    repetition: $repetition,
    model: $model,
    served_model: $served_model,
    profile_container: $profile_container,
    context_window: $context_window,
    loom_base_sha: $loom_base_sha,
    benchmark_commit: $benchmark_commit,
    protocol_sha256: $protocol_sha256,
    pi_version: $pi_version,
    worktree: $worktree,
    baseline_typecheck: $baseline_typecheck,
    started: $started
  }' > "$RUN_DIR/run.json"

# The brief goes to a file, and /loom gets a ONE-LINE argument pointing at it.
#
# Pasting the brief inline does not survive the TUI: `/loom` expands to a
# 50k-character skill body, and a multi-line paste can submit on its first
# newline. When that happens the model receives a full orchestration skill with
# no task — and it does not stop and ask, it invents one. The first shakedown
# run lost this way, confabulating an entire project that did not exist.
#
# The path is deliberately neutral: nothing in it says "benchmark", names a
# model, or hints that the run is being compared.
TASK_FILE="/tmp/task-brief.md"
sed -n '/^---$/,$p' "$BENCH_DIR/frozen/brief.md" | tail -n +2 > "$TASK_FILE"
LOOM_ARG="Read $TASK_FILE and carry out the task it describes."

cat <<EOF

Run $RUN_ID prepared.

  worktree : $WORKTREE
  record   : $RUN_DIR
  model    : $MODEL  (serving '$SERVED')
  profile  : $PROFILE_CONTAINER
  context  : $CONTEXT_WINDOW
  protocol : $PROTOCOL_SHA

Before launching, confirm cortex is disabled for this session — recalled memory
from an earlier arm is the one contamination channel that leaves no trace in
the diff. After the run, grep the transcript for CORTEX_MEMORY_START; if it is
there, the run is void.

  cd "$WORKTREE"
  pi --model $MODEL

Then type EXACTLY this one line — it is short on purpose, so no paste can be
truncated and no newline can submit it early:

  /loom $LOOM_ARG

Sanity check before you answer anything: the model's first move must be to read
$TASK_FILE and talk about a JSONL relay codec. If it starts planning some other
project, the task did not arrive — abort and re-run this script.

Answer only from frozen/answer-key.md, logging every exchange to:

  $RUN_DIR/interview.md

The valid stop point is immediately after decomposition: the active graph may
say phase=execute/current_wave=1, but every task must still be pending and no
Wave 1 child may have started. If implementation starts, stop and preserve the
run as an invalid stop-boundary result.

Copy the parent Pi transcript to $RUN_DIR/session.jsonl. The planning grader
captures brainstorm, spec, plan, alignment, and task graph from the worktree.
It also attests every executed child and fails closed on missing evidence:

  bash "$BENCH_DIR/scripts/verify-run-models.sh" "$RUN_DIR"
  bash "$BENCH_DIR/scripts/grade-planning.sh" "$WORKTREE" "$RUN_DIR"

EOF
