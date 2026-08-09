#!/usr/bin/env bash
# Static contract test for the pinned DeepSeek-V4-Flash release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/run-ds4-v20-r33.sh"
DOWNLOAD="$ROOT/scripts/download-ds4-flash.sh"
DOC="$ROOT/docs/new-desktop-install.md"
IMAGE="voipmonitor/vllm:gilded-gnosis-v20-vllmfa13d33-b12x06db0f4-fi1ac6942-cu132-20260809-r33"
DIGEST="sha256:fdde59fed7f9fc12f9fd5ef1b3b3ea8d5097bf10ebad54b348497102c3a83f82"
MODEL_REV="9e165c30e2704aec5d9d593cce3eebd58bbef1cb"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

[[ -x "$RUN" ]] || fail "$RUN is not executable"
[[ ! -e "$ROOT/scripts/run-ds4-v20-r31.sh" ]] || fail "stale r31 launcher still exists"
bash -n "$RUN"
bash -n "$DOWNLOAD"

contains "$RUN" "$IMAGE@$DIGEST"
contains "$RUN" 'NAME="ds4-0731-r33"'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" "printf 'VLLM_API_KEY=%s\\n'"
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "$RUN exposes VLLM_API_KEY in process arguments"
fi
contains "$RUN" 'B12X_PCIE_TP2_REMOTE_PUSH=0'
contains "$RUN" 'B12X_PCIE_TP4_REMOTE_PUSH=0'
contains "$RUN" 'B12X_PCIE_TP8_OWNER_REDUCE=1'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-1048576}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"'
contains "$RUN" '-e MAX_MODEL_LEN="$MAX_MODEL_LEN"'
contains "$DOWNLOAD" "REV=\"$MODEL_REV\""
contains "$DOC" 'models/ds4dspark-v20-r33.md'
contains "$DOC" "$IMAGE"
contains "$DOC" "$DIGEST"

printf 'PASS: DS4 r33 release contract is internally consistent\n'
