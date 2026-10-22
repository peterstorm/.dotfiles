#!/usr/bin/env bash
# Move the served Maya commit (and rebuild the engine in place), with automatic
# rollback: stop the container, pin both copies of the run script, check out,
# rebuild inside the pinned toolchain image, launch, then prove /health, the
# authenticated model list AND a real completion. Any failure rebuilds OLD and
# relaunches it, so a bad upgrade cannot leave the desktop without inference
# (there is no cloud fallback in models.json).
#
# The 2026-10-22 upgrade ran this logic verbatim as ~/ds41-cutover-v121.sh
# (sha256 a1261dd9…): 8d9a9b5/v1.1.17 -> b3fa99e/v1.1.21 + PR #356, in 4m50s.
#
# Usage: cutover-ds41-1017-maya-exl35.sh [delay_seconds]
#   NEW=<commit> OLD=<commit> JOBS=<n> override the defaults (NEW defaults to
#   the v1.1.21 + conversation-slots merge, OLD to the v1.1.17 rollback target).
#   The delay exists so a caller can finish its last generation before the
#   engine dies. Log and receipt land in ~/.local/state/ds41-maya/.
set -uo pipefail

MAYA=/models/ds41/project-maya
NEW="${NEW:-b3fa99ec244e7885ec04ef456eac0d52474dba95}"
OLD="${OLD:-8d9a9b5d705049a87da853717cdc59440252de30}"
JOBS="${JOBS:-8}"
IMG=sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a
NAME=ds41-1017-maya-exl35
RUN="$HOME/.local/share/ds41-maya/repo/scripts/inference/deepseek/ds41-1017-maya/run-ds41-1017-maya-exl35.sh"
RUN_REPO="$HOME/.dotfiles/scripts/inference/deepseek/ds41-1017-maya/run-ds41-1017-maya-exl35.sh"
KEYFILE_HELPER="$HOME/.local/share/ds41-maya/repo/scripts/inference/shared/inference-api-key.sh"
STATE="$HOME/.local/state/ds41-maya"
mkdir -p "$STATE"
LOG="$STATE/cutover-$(date +%Y%m%d-%H%M%S).log"
exec >>"$LOG" 2>&1
say() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }

DELAY="${1:-0}"
say "cutover scheduled: delay=${DELAY}s new=$NEW old=$OLD"

# the pin lives in two copies of one file (the deployed mirror and the repo): write both, or fail
pin() {
  local f
  for f in "$RUN" "$RUN_REPO"; do
    [ -f "$f" ] || continue
    sed -i "s|^MAYA_COMMIT=\"[0-9a-f]*\"|MAYA_COMMIT=\"$1\"|" "$f"
    grep -q "^MAYA_COMMIT=\"$1\"" "$f" || { say "ERROR: could not pin MAYA_COMMIT=$1 in $f"; return 1; }
  done
  say "pinned MAYA_COMMIT=$1"
}

build() {  # $1 = commit, $2 = jobs
  say "checkout $1 + rebuild (jobs=$2)"
  git -C "$MAYA" checkout -q "$1" || { say "ERROR: checkout $1 failed"; return 1; }
  docker rm -f maya-cutover-build >/dev/null 2>&1
  docker run --rm --name maya-cutover-build --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v /models/ds41:/models/ds41 -w "$MAYA" --entrypoint bash "$IMG" -c "
      cmake -G Ninja -DCMAKE_MAKE_PROGRAM=/opt/venv/bin/ninja -S . -B build \
        -DCMAKE_BUILD_TYPE=Release -DSTRATA_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 \
        -DSTRATA_NATIVE_EXPERTS=ON -DSTRATA_BUILD_TESTS=OFF \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc -DCUDAToolkit_ROOT=/usr/local/cuda \
        -DSTRATA_GGML_DIR=$MAYA/third_party/llama.cpp >/dev/null && \
      cmake --build build --target maya-ds4 -j$2" || { say "ERROR: build of $1 failed"; return 1; }
  [ -x "$MAYA/build/maya-ds4" ] || { say "ERROR: no engine after build of $1"; return 1; }
  # the stamp is maya's own source hash from maya's own code: computed, never guessed
  local src
  src="$(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v /models/ds41:/models/ds41 -w "$MAYA" \
    --entrypoint /opt/venv/bin/python3 "$IMG" -c "import setup as S; print(S.source_hash(S.ENGINE_SOURCES))")" \
    || { say "ERROR: could not compute the source stamp"; return 1; }
  python3 - "$MAYA/build/MAYA-BUILD.json" "$src" <<'PY' || { say "ERROR: could not write the build stamp"; return 1; }
import json, sys, time
path, src = sys.argv[1], sys.argv[2]
meta = {"src": src, "archs": [120], "gpu_ids": [0, 1], "nvcc": "/usr/local/cuda/bin/nvcc",
        "host_compiler": None, "llama": "/models/ds41/project-maya/third_party/llama.cpp",
        "lib_dirs": ["/usr/local/cuda-13.4/lib64", "/usr/local/cuda-13.4/targets/x86_64-linux/lib"],
        "date": time.strftime("%Y-%m-%d %H:%M"), "targets": ["maya-ds4"]}
open(path, "w").write(json.dumps(meta, indent=1))
PY
  say "engine built: src=$src sha256=$(sha256sum "$MAYA/build/maya-ds4" | cut -c1-16)"
}

stop_engine() {
  say "stopping $NAME"
  docker stop -t 45 "$NAME" >/dev/null 2>&1
  local i
  for i in $(seq 1 30); do
    if ! ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then say "port 8000 free"; return 0; fi
    sleep 2
  done
  say "ERROR: port 8000 still listening after stop"; return 1
}

start_engine() {
  "$RUN" --launch || { say "ERROR: launch failed"; return 1; }
  docker update --restart=unless-stopped "$NAME" >/dev/null 2>&1 || say "WARN: could not promote restart policy"
  say "launched $NAME"
}

# The invariant is "the engine emitted tokens", not "the content field is set":
# a reasoning model legitimately answers with content null and finish_reason
# length, so accepting only content would roll a healthy engine back.
health_gate() {  # $1 = seconds to wait
  local deadline=$((SECONDS + $1)) key body t0 t1
  # shellcheck disable=SC1090
  source "$KEYFILE_HELPER"
  while ((SECONDS < deadline)); do
    if curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/health 2>/dev/null \
         | jq -e '.status == "ok" and .unloaded == false' >/dev/null 2>&1; then
      inference_resolve_client_keyfile || { say "ERROR: no client key"; return 1; }
      key="$(<"$INFERENCE_CLIENT_KEYFILE")"
      if curl -fsS --connect-timeout 2 --max-time 10 -H "Authorization: Bearer $key" \
           http://127.0.0.1:8000/v1/models 2>/dev/null \
         | jq -e '.data | length == 1 and .[0].id == "deepseek-v4.1-flash"' >/dev/null 2>&1; then
        t0=$(date +%s.%N)
        body="$(curl -fsS --connect-timeout 5 --max-time 180 -H "Authorization: Bearer $key" \
          -H 'Content-Type: application/json' \
          -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":24,"temperature":0}' \
          http://127.0.0.1:8000/v1/chat/completions 2>/dev/null)"
        t1=$(date +%s.%N)
        if jq -e '.choices[0].message | ((.content // "") + (.reasoning_content // "")) | length > 0' <<<"$body" >/dev/null 2>&1; then
          say "HEALTHY: /health ok, model deepseek-v4.1-flash, completion in $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')s"
          jq -r '"  answer: " + (((.choices[0].message.content // .choices[0].message.reasoning_content) | gsub("\\s+"; " "))[0:160]) + " | prefill " + (.timings.prompt_per_second // 0 | tostring) + " tok/s, decode " + (.timings.predicted_per_second // 0 | tostring) + " tok/s, drafts " + (.timings.draft_n_accepted // 0 | tostring) + "/" + (.timings.draft_n // 0 | tostring)' <<<"$body" >>"$LOG"
          return 0
        fi
        say "health ok but the completion failed; retrying"
      fi
    fi
    sleep 5
  done
  say "ERROR: $NAME did not serve a working model within ${1}s"; return 1
}

receipt() {  # $1 = outcome label
  local out="$STATE/cutover-latest.txt"
  {
    echo "outcome=$1"
    echo "time=$(date -Is)"
    echo "maya_head=$(git -C "$MAYA" rev-parse HEAD)"
    echo "pin=$(sed -n 's/^MAYA_COMMIT="\([0-9a-f]*\)"/\1/p' "$RUN")"
    echo "engine_sha256=$(sha256sum "$MAYA/build/maya-ds4" | cut -d' ' -f1)"
    echo "engine_stamp=$(jq -c . "$MAYA/build/MAYA-BUILD.json")"
    echo "container_image=$(docker inspect "$NAME" --format '{{.Image}}' 2>/dev/null)"
    echo "container_maya_label=$(docker inspect "$NAME" --format '{{index .Config.Labels "ai.peterstorm.inference.maya-commit"}}' 2>/dev/null)"
    echo "restart_policy=$(docker inspect "$NAME" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)"
    echo "gpus=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | tr '\n' ' ')"
    echo "--- engine log: placement/memory/version ---"
    docker logs "$NAME" 2>&1 | grep -iE "experts|vram|ram|dspark|context|slots|version|READY|skipped" | tail -25
  } >"$out" 2>&1
  say "receipt: $out"
}

main() {
  git -C "$MAYA" cat-file -e "$NEW^{commit}" || { say "ERROR: $NEW is not in $MAYA"; return 1; }
  [ -z "$(git -C "$MAYA" status --porcelain)" ] || { say "ERROR: $MAYA has local changes"; return 1; }
  stop_engine || return 1
  pin "$NEW" || return 1
  build "$NEW" "$JOBS" || return 1
  start_engine || return 1
  health_gate 2400 || return 1
  receipt "UPGRADED $NEW (conversation slots only if the run script passes STRATA_DS4_SLOT_*)"
  return 0
}

rollback() {
  say "ROLLBACK to $OLD"
  pin "$OLD" || say "ERROR: could not restore the pin - restore it by hand"
  if build "$OLD" "$JOBS" && start_engine && health_gate 2400; then
    receipt "ROLLED BACK to $OLD (new engine failed)"
  else
    receipt "BROKEN: neither engine serves - needs a human"
    say "BROKEN: neither engine serves"
  fi
}

sleep "$DELAY"
say "cutover starting"
if main; then
  say "CUTOVER OK"
else
  rollback
fi
say "cutover finished; log: $LOG"
