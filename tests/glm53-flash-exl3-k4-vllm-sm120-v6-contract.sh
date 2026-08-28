#!/usr/bin/env bash
# Static contract for the unqualified text-only GLM-5.3 EXL3 K4 v84 FP8-DS-MLA v6 profile.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v6-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v6.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v6.sh"
V5_RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v5.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

for file in "$PULL" "$RUN" "$SWITCH" "$V5_RUN"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done

contains "$PULL" 'sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$PULL" 'sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578'
contains "$PULL" 'sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692'
contains "$PULL" 'FLASHINFER_MLA_SPARSE_SM120'
contains "$PULL" 'find_spec("instanttensor")'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-393216}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.986}"'
contains "$RUN" '[ "$GPU_MEMORY_UTILIZATION" = 0.986 ]'
contains "$RUN" 'verify-glm53-flash-exl3-k4-v1.sh'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k"'
contains "$RUN" '--enable-request-id-headers'
contains "$RUN" '--enable-force-include-usage'
contains "$RUN" '--enable-per-request-metrics'
contains "$RUN" '--enable-prompt-tokens-details'
contains "$RUN" '--language-model-only'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--decode-context-parallel-size 2'
contains "$RUN" '--dcp-comm-backend a2a'
contains "$RUN" '--kv-cache-dtype fp8_ds_mla'
contains "$RUN" '--attention-backend FLASHINFER_MLA_SPARSE_SM120'
contains "$RUN" '--load-format instanttensor'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--default-chat-template-kwargs '\''{"clear_thinking":true}'\'''
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'\'''
contains "$RUN" 'ai.peterstorm.inference.capacity-evidence=fp8-ds-mla-author-claim-approximately-700k-unqualified'
contains "$RUN" 'ai.peterstorm.inference.kv-cache=fp8_ds_mla'
contains "$RUN" '-e VLLM_B12X_GLM_NOPE_NVFP4=1'
contains "$RUN" '-e VLLM_ENABLE_PCIE_ALLREDUCE=1'
contains "$RUN" '-e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" '--gpus all'
for forbidden in '--runtime nvidia' '--chat-template /opt/glm53/chat_template.multimodal.jinja' '--limit-mm-per-prompt' '--mm-encoder-attn-backend' '--kv-cache-dtype nvfp4_ds_mla' '--no-enable-prefix-caching' 'method":"dflash'; do
  if grep -Fq -- "$forbidden" "$RUN"; then
    echo "FAIL: text FP8 v6 contains forbidden multimodal/NVFP4/DFlash fragment: $forbidden" >&2
    exit 1
  fi
done
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi

contains "$V5_RUN" '--kv-cache-dtype nvfp4_ds_mla'
contains "$V5_RUN" '--limit-mm-per-prompt '\''{"image":4,"video":0}'\'''
contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v6"'
contains "$SWITCH" 'EXPECTED_MODEL="glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k"'
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v5'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v6'

jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k") |
  .input == ["text"] and
  .contextWindow == 393216 and
  .defaultThinkingLevel == "max"
' "$PI_MODELS" >/dev/null

set +e
output="$(MAX_MODEL_LEN=393217 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: MAX_MODEL_LEN=393217 status=$status" >&2; exit 1; }
grep -Fq 'MAX_MODEL_LEN must be an integer in [1, 393216]' <<<"$output"

set +e
output="$(MAX_NUM_BATCHED_TOKENS=2049 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: MAX_NUM_BATCHED_TOKENS=2049 status=$status" >&2; exit 1; }
grep -Fq 'MAX_NUM_BATCHED_TOKENS must be an integer in [1, 2048]' <<<"$output"

set +e
output="$(GPU_MEMORY_UTILIZATION=0.985 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: GPU_MEMORY_UTILIZATION=0.985 status=$status" >&2; exit 1; }
grep -Fq 'fixes GPU_MEMORY_UTILIZATION at 0.986' <<<"$output"

echo 'PASS: GLM-5.3 v84 text FP8-DS-MLA/MTP3 v6 is immutable, 384K-bounded, rollback-safe, and unqualified'
