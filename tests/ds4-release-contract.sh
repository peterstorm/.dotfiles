#!/usr/bin/env bash
# Static contract test for the pinned DeepSeek-V4-Flash Infernal Invocation release.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh"
DOWNLOAD="$ROOT/scripts/inference/deepseek/download-ds4-flash.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
DOC="$ROOT/docs/runbooks/new-desktop-install.md"
RUNBOOK="$ROOT/docs/runbooks/ds4-infernal-invocation-r18-runbook-2026-08-22.md"
IMAGE="voipmonitor/vllm:infernal-invocation-vllmf0fa1ce-b12x75787c7-fi1ac6942-cu133-torch213-20260818-r18"
DIGEST="sha256:414ec7d0d28358cfd8af0697f330f5c8acbb80e4dc4e5ba69c9fd5b5855ea804"
IMAGE_ID="sha256:955e088a85b5378b00275842bc839eea8cb04ca0782ed79eaa3a967d11fd22e5"
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
[[ ! -e "$ROOT/scripts/inference/deepseek/run-ds4-v20-r33.sh" ]] || fail "stale r33 launcher still exists"
bash -n "$RUN"
bash -n "$DOWNLOAD"

conflict_status=0
conflict_output="$(
  LMCACHE_MODE=disk KV_OFFLOADING_SIZE=1 NATIVE_L2_GB=0 bash "$RUN" 2>&1
)" || conflict_status=$?
[[ "$conflict_status" -eq 2 ]] || fail "mutually exclusive KV backends did not fail with status 2"
grep -Fq 'cannot be enabled together' <<<"$conflict_output" \
  || fail "mutually exclusive KV backend error was not reported"

contains "$RUN" "$IMAGE@$DIGEST"
contains "$RUN" 'NAME="ds4-infernal-invocation-cu133-r18"'
contains "$RUN" 'CACHE_HOST="/models/vllm-cache/infernal-invocation-r18"'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$RUN" 'inference_prepare_api_key "${VLLM_API_KEY:-}"'
contains "$RUN" 'inference_write_private_file "$ENVFILE" <<EOF'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "$RUN exposes VLLM_API_KEY in process arguments"
fi
contains "$RUN" '--entrypoint /usr/local/bin/lmcache-mp-wrapper.sh'
contains "$RUN" '/usr/local/bin/serve-ds4-flash.sh'
contains "$RUN" 'DRAFT_SAMPLE_METHOD=probabilistic'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-1048576}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"'
contains "$RUN" '-e GRAPH=auto'
contains "$RUN" 'LMCACHE_MODE="${LMCACHE_MODE:-off}"'
contains "$RUN" 'NATIVE_L2_GB="${NATIVE_L2_GB:-0}"'
contains "$RUN" 'native vLLM KV offload and LMCache cannot be enabled together'
contains "$RUN" 'docker rm -f ds4-0731-r33'
contains "$DOWNLOAD" "REV=\"$MODEL_REV\""
contains "$CATALOG" 'ds4-infernal-invocation-cu133-r18'
contains "$DOC" 'models/ds4dspark-infernal-invocation-r18.md'
contains "$DOC" "$IMAGE"
contains "$DOC" "$DIGEST"
contains "$DOC" "$IMAGE_ID"
contains "$RUNBOOK" 'rtx6kpro/blob/9cfa57adc77a60f8ec800c976b831356f32d8190/models/ds4dspark-infernal-invocation-r18.md'
contains "$RUNBOOK" 'blackwell-llm-docker/07c6aa551bdfb7a97b8cfc7345eeefdc9bf1536f/examples/docker-compose-ds4-infernal-invocation-cu133-r18.yml'
contains "$RUNBOOK" "$IMAGE"
contains "$RUNBOOK" "$DIGEST"
contains "$RUNBOOK" "$IMAGE_ID"
contains "$RUNBOOK" "$MODEL_REV"

printf 'PASS: DS4 Infernal Invocation r18 release contract is internally consistent\n'
