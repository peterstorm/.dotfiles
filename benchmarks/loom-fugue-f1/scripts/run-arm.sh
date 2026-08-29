#!/usr/bin/env bash
# Prepare one immutable Fugue F1 planning run and print its supervised RPC command.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(git -C "$BENCH_DIR" rev-parse --show-toplevel)"
FUGUE="${FUGUE_REPO:-$HOME/dev/agentic/fugue}"
LOOM_RUNTIME="${LOOM_RUNTIME_REPO:-$HOME/dev/claude-plugins/loom-benchmark-runtime-3815f65}"
# shellcheck source=benchmarks/loom-fugue-f1/suite.sh
source "$BENCH_DIR/suite.sh"
# shellcheck source=benchmarks/loom-model-ab/scripts/arms.sh
source "$ROOT/benchmarks/loom-model-ab/scripts/arms.sh"

usage() {
  echo "usage: $0 (--list | --probe <arm> | <arm> <repetition>)" >&2
}

if (($# == 1)) && [[ "$1" == --list ]]; then
  printf '%-20s %-58s %-42s %s\n' ARM PI_MODEL SERVED_MODEL CONTEXT
  while IFS= read -r arm; do
    IFS=$'\t' read -r model served context _ <<<"$(fugue_benchmark_arm_record "$arm")"
    printf '%-20s %-58s %-42s %s\n' "$arm" "$model" "$served" "$context"
  done < <(fugue_benchmark_arm_ids)
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
[[ "$REP" =~ ^[0-9]+$ ]] || { echo 'repetition must be an integer' >&2; exit 2; }
IFS=$'\t' read -r MODEL EXPECTED CONTEXT_WINDOW PROFILE_CONTAINER START_HINT PROFILE_LABEL \
  <<<"$(fugue_benchmark_arm_record "$ARM")"

SELECTOR="${MODEL#desktop-vllm/}"
MODEL_ID="${SELECTOR%%:*}"
THINKING_LEVEL="${SELECTOR##*:}"
PI_MODELS="$ROOT/pi/models.json"
jq -e --arg id "$MODEL_ID" --arg level "$THINKING_LEVEL" --argjson context "$CONTEXT_WINDOW" '
  any(.providers["desktop-vllm"].models[];
    .id == $id and .contextWindow == $context and .thinkingLevelMap[$level] != null)
' "$PI_MODELS" >/dev/null || {
  echo "Pi model catalog does not expose exact arm selector $MODEL at context $CONTEXT_WINDOW" >&2
  exit 1
}
PI_MODELS_SHA="$(sha256sum "$PI_MODELS" | cut -d' ' -f1)"

TARGET_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.target.base_sha')"
TARGET_REMOTE="$(fugue_source_lock_value "$BENCH_DIR" '.target.repository')"
RUNTIME_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.loom_runtime.base_sha')"
EXPECTED_PI="$(fugue_source_lock_value "$BENCH_DIR" '.pi.version')"
PROTOCOL_SHA="$(fugue_protocol_sha "$BENCH_DIR")"

if ! git -C "$ROOT" diff --quiet -- benchmarks/loom-fugue-f1 tests/loom-fugue-f1-contract.sh ||
   [[ -n "$(git -C "$ROOT" ls-files --others --exclude-standard -- benchmarks/loom-fugue-f1 tests/loom-fugue-f1-contract.sh)" ]]; then
  echo 'benchmark harness is not committed exactly; refusing an unidentifiable run' >&2
  exit 1
fi
[[ "$(git -C "$FUGUE" rev-parse "$TARGET_SHA^{commit}")" == "$TARGET_SHA" ]] || { echo 'pinned Fugue commit is unavailable' >&2; exit 1; }
[[ "$(git -C "$LOOM_RUNTIME" rev-parse HEAD)" == "$RUNTIME_SHA" ]] || {
  echo "Loom runtime mismatch: expected $RUNTIME_SHA at $LOOM_RUNTIME" >&2
  exit 1
}
[[ "$(pi --version)" == "$EXPECTED_PI" ]] || { echo "Pi version mismatch; expected $EXPECTED_PI" >&2; exit 1; }
jq -e \
  --arg suite "$FUGUE_SUITE_ID" \
  --arg target "$TARGET_SHA" \
  --arg runtime "$RUNTIME_SHA" \
  '.suite_id == $suite and .target_base_sha == $target and .loom_runtime_sha == $runtime and .typecheck == "clean" and .tests == "clean" and .total_tests > 0' \
  "$BENCH_DIR/baseline/receipt.json" >/dev/null || {
    echo "missing or stale baseline; run $BENCH_DIR/scripts/baseline.sh" >&2
    exit 1
  }

PI_SETTINGS="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json"
if ! node - "$PI_SETTINGS" "$(realpath -e "$LOOM_RUNTIME")" <<'NODE'
const fs = require("node:fs");
const [file, runtime] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(file, "utf8"));
const packages = settings.packages ?? [];
const memoryActive = packages.some((value) => /(cortex|obsidian)/i.test(value));
const loomPackages = packages.filter((value) => /(^|\/)loom(?:\/)?$|loom-benchmark-runtime/i.test(value));
if (memoryActive || loomPackages.length !== 1 || loomPackages[0] !== runtime) process.exit(1);
NODE
then
  echo 'Benchmark isolation is inactive: memory packages remain or Pi is not registered to the pinned Loom runtime.' >&2
  echo "Activate it first: bash $BENCH_DIR/scripts/isolation.sh off" >&2
  exit 1
fi

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
[[ -n "$API_KEY" ]] || { echo 'could not resolve inference API key' >&2; exit 1; }
ESCAPED_API_KEY="${API_KEY//\\/\\\\}"
ESCAPED_API_KEY="${ESCAPED_API_KEY//\"/\\\"}"
MODELS_JSON="$({ printf 'header = "Authorization: Bearer %s"\n' "$ESCAPED_API_KEY"; } \
  | curl --config - -fsS -m 15 "${INFERENCE_URL:-http://192.168.0.80:8000}/v1/models" 2>/dev/null)" || MODELS_JSON=''
SERVED="$(jq -er '.data | select(type == "array" and length == 1) | .[0].id | select(type == "string")' \
  <<<"$MODELS_JSON" 2>/dev/null)" || SERVED=''
unset API_KEY ESCAPED_API_KEY MODELS_JSON

if [[ "$SERVED" != "$EXPECTED" ]]; then
  cat >&2 <<EOF
Backend mismatch: serving '${SERVED:-<nothing or multiple models>}', arm '$ARM' requires '$EXPECTED'.
Start $PROFILE_LABEL with:
  $START_HINT
EOF
  exit 1
fi
PROFILE_INSPECT="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${INFERENCE_HOST:-desktop}" \
  "docker inspect --format='{{.State.Running}}\t{{index .Config.Labels \"ai.peterstorm.inference.profile\"}}\t{{index .Config.Labels \"ai.peterstorm.inference.image-config\"}}' '$PROFILE_CONTAINER'" 2>/dev/null || true)"
IFS=$'\t' read -r PROFILE_RUNNING OBSERVED_PROFILE IMAGE_CONFIG <<<"$PROFILE_INSPECT"
[[ "$PROFILE_RUNNING" == true && "$OBSERVED_PROFILE" == "$PROFILE_CONTAINER" && "$IMAGE_CONFIG" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "runtime profile identity mismatch: expected running $PROFILE_CONTAINER, observed '${OBSERVED_PROFILE:-<none>}' with image config '${IMAGE_CONFIG:-<none>}'" >&2
  echo "start with: $START_HINT" >&2
  exit 1
}

if [[ "$PROBE_ONLY" == true ]]; then
  printf 'READY: suite=%s arm=%s model=%s served=%s context=%s profile=%s image_config=%s target=%s runtime=%s protocol=%s\n' \
    "$FUGUE_SUITE_ID" "$ARM" "$MODEL" "$SERVED" "$CONTEXT_WINDOW" "$OBSERVED_PROFILE" "$IMAGE_CONFIG" "$TARGET_SHA" "$RUNTIME_SHA" "$PROTOCOL_SHA"
  exit 0
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$ARM-$REP"
RUN_DIR="$BENCH_DIR/runs/$RUN_ID"
WORKTREE="${FUGUE_WORKTREE_ROOT:-$FUGUE/..}/fugue-bench-$RUN_ID"
[[ ! -e "$RUN_DIR" && ! -e "$WORKTREE" ]] || { echo "run already exists: $RUN_ID" >&2; exit 1; }

git -C "$FUGUE" worktree add --detach "$WORKTREE" "$TARGET_SHA"
WORKTREE="$(cd "$WORKTREE" && pwd)"
if [[ ! -e "$WORKTREE/node_modules" && -d "$FUGUE/node_modules" ]]; then
  ln -s "$FUGUE/node_modules" "$WORKTREE/node_modules"
fi
if [[ ! -e "$WORKTREE/packages/framework/node_modules" && -d "$FUGUE/packages/framework/node_modules" ]]; then
  ln -s "$FUGUE/packages/framework/node_modules" "$WORKTREE/packages/framework/node_modules"
fi
mkdir -p "$RUN_DIR"
printf '%s\n' "$TARGET_SHA" > "$RUN_DIR/base_sha"

(cd "$WORKTREE" && timeout 300 bun run --filter @fuguejs/framework typecheck) \
  > "$RUN_DIR/baseline-typecheck.log" 2>&1 || {
    echo 'isolated target worktree does not typecheck; preserving it for diagnosis' >&2
    exit 1
  }
fugue_protocol_manifest "$BENCH_DIR" > "$RUN_DIR/protocol.sha256"
[[ "$(sha256sum "$RUN_DIR/protocol.sha256" | cut -d' ' -f1)" == "$PROTOCOL_SHA" ]] || {
  echo 'protocol manifest hash drifted while preparing run' >&2
  exit 1
}

jq -n \
  --arg benchmark_kind 'planning-only' \
  --arg suite_id "$FUGUE_SUITE_ID" \
  --arg protocol_version "$FUGUE_PROTOCOL_VERSION" \
  --arg protocol_sha256 "$PROTOCOL_SHA" \
  --arg run_id "$RUN_ID" \
  --arg arm "$ARM" \
  --argjson repetition "$REP" \
  --arg model "$MODEL" \
  --arg served_model "$SERVED" \
  --arg profile_container "$PROFILE_CONTAINER" \
  --arg image_config "$IMAGE_CONFIG" \
  --arg pi_models_sha256 "$PI_MODELS_SHA" \
  --argjson context_window "$CONTEXT_WINDOW" \
  --arg target_repository "$TARGET_REMOTE" \
  --arg target_base_sha "$TARGET_SHA" \
  --arg loom_runtime_sha "$RUNTIME_SHA" \
  --arg benchmark_commit "$(git -C "$ROOT" rev-parse HEAD)" \
  --arg pi_version "$EXPECTED_PI" \
  --arg worktree "$WORKTREE" \
  --arg started "$(date -Is)" \
  '{
    benchmark_kind: $benchmark_kind,
    suite_id: $suite_id,
    protocol_version: $protocol_version,
    protocol_sha256: $protocol_sha256,
    stop_before: "wave-1-implementation",
    run_id: $run_id,
    arm: $arm,
    repetition: $repetition,
    model: $model,
    served_model: $served_model,
    profile_container: $profile_container,
    image_config: $image_config,
    pi_models_sha256: $pi_models_sha256,
    context_window: $context_window,
    target: { repository: $target_repository, base_sha: $target_base_sha },
    loom_runtime_sha: $loom_runtime_sha,
    benchmark_commit: $benchmark_commit,
    pi_version: $pi_version,
    worktree: $worktree,
    baseline_typecheck: "clean",
    started: $started
  }' > "$RUN_DIR/run.json"

TASK_FILE="/tmp/fugue-f1-task-$RUN_ID.md"
cp "$BENCH_DIR/frozen/brief.md" "$TASK_FILE"
LOOM_PROMPT="/loom Read $TASK_FILE and carry out the task it describes."

printf '\nPrepared %s\n\n' "$RUN_ID"
printf '  worktree: %s\n  run:      %s\n  model:    %s\n  target:   %s\n  runtime:  %s\n  protocol: %s\n\n' \
  "$WORKTREE" "$RUN_DIR" "$MODEL" "$TARGET_SHA" "$RUNTIME_SHA" "$PROTOCOL_SHA"
echo 'Run the supervised RPC driver; answer only from frozen/answer-key.md:'
printf '  bun %q --worktree %q --run-dir %q --model %q --prompt %q\n\n' \
  "$BENCH_DIR/scripts/rpc-driver.ts" "$WORKTREE" "$RUN_DIR" "$MODEL" "$LOOM_PROMPT"
echo 'Then grade:'
printf '  bash %q %q %q\n' "$BENCH_DIR/scripts/grade-planning.sh" "$WORKTREE" "$RUN_DIR"
