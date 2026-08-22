#!/usr/bin/env bash
# Prepare one benchmark arm: isolated worktree, frozen contract, recorded
# baseline. Stops short of launching Pi — the run itself is interactive,
# because the whole point is that the model conducts its own interview.
#
#   bash scripts/run-arm.sh ds4  1
#   bash scripts/run-arm.sh qwen 1
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOM="${LOOM_REPO:-$HOME/dev/claude-plugins/loom}"

(($# == 2)) || { echo "usage: $0 <ds4|qwen> <repetition>" >&2; exit 2; }
ARM="$1"; REP="$2"

case "$ARM" in
  ds4)  MODEL="desktop-vllm/deepseek-v4-flash:max" ;;
  qwen) MODEL="desktop-vllm/qwen3.8-27b:xhigh" ;;
  *)    echo "unknown arm: $ARM (expected ds4 or qwen)" >&2; exit 2 ;;
esac

[[ "$REP" =~ ^[0-9]+$ ]] || { echo "repetition must be an integer" >&2; exit 2; }

RUN_ID="$(date +%Y%m%dT%H%M%S)-$ARM-$REP"
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
                   ~/.config/sops-nix/secrets/vllm-api-key; do
    [[ -r "$candidate" ]] && { cat "$candidate"; return 0; }
  done
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${INFERENCE_HOST:-desktop}" \
    'if [ -r ~/.config/ds4-flash/api-key ]; then cat ~/.config/ds4-flash/api-key; else cat ~/.config/qwen38/api-key; fi' \
    2>/dev/null
}

API_KEY="$(resolve_key)"
[[ -n "$API_KEY" ]] || { echo "could not resolve an inference api-key locally or from the desktop" >&2; exit 1; }
ESCAPED_API_KEY="${API_KEY//\\/\\\\}"
ESCAPED_API_KEY="${ESCAPED_API_KEY//\"/\\\"}"

# Read the credential through curl's stdin config so it never appears in argv.
SERVED="$({
  printf 'header = "Authorization: Bearer %s"\n' "$ESCAPED_API_KEY"
} | curl --config - -fsS -m 15 \
  "${INFERENCE_URL:-http://192.168.0.80:8000}/v1/models" 2>/dev/null \
  | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')" || true

EXPECTED="${MODEL#desktop-vllm/}"; EXPECTED="${EXPECTED%%:*}"
if [[ "$SERVED" != "$EXPECTED" ]]; then
  cat >&2 <<EOF
Backend mismatch: :8000 is serving '${SERVED:-<nothing>}', arm '$ARM' needs '$EXPECTED'.

  → DS4 : docker rm -f qwen38-27b-bf16-dspark-sglang qwen38-27b-bf16-dspark-vllm; bash ~/.dotfiles/scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh
  → Qwen: docker rm -f ds4-infernal-invocation-cu133-r18; bash ~/.dotfiles/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-sglang.sh

Wait for an authenticated /v1/models before retrying — a cold start takes minutes.
EOF
  exit 1
fi

# --- isolated worktree off a recorded baseline ------------------------------

BASE_SHA="$(git -C "$LOOM" rev-parse HEAD)"
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
  echo "  WARNING: the worktree does not typecheck before the run — fix this first," >&2
  echo "  or SC-001 is unreachable and the instrument measures nothing." >&2
fi
cat > "$RUN_DIR/run.json" <<JSON
{
  "run_id": "$RUN_ID",
  "arm": "$ARM",
  "repetition": $REP,
  "model": "$MODEL",
  "served_model": "$SERVED",
  "loom_base_sha": "$BASE_SHA",
  "worktree": "$WORKTREE",
  "baseline_typecheck": "$BASELINE_TSC",
  "started": "$(date -Is)"
}
JSON

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

When the run ends, capture spec.md, plan.md, the task graph and the wave-gate
result into $RUN_DIR, then:

  bash scripts/grade-implementation.sh "$WORKTREE" "$RUN_DIR"

EOF
