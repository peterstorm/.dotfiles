#!/usr/bin/env bash
# Static contract for the unqualified multimodal NVFP4 fair-prefill GLM-5.3 EXL3 K4 v7 profile.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v7-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v7.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v7.sh"
V5_RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v5.sh"
V6_RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v6.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

for file in "$PULL" "$RUN" "$SWITCH" "$V5_RUN" "$V6_RUN"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done

contains "$PULL" 'sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$PULL" 'sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578'
contains "$PULL" 'sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692'
contains "$PULL" 'native-pytorch-fallback-when-vllm-flash-attn-layers-absent'
contains "$PULL" '"TORCH_SDPA" in AttentionBackendEnum.__members__'
contains "$PULL" '"B12X_MLA_SPARSE" in AttentionBackendEnum.__members__'
contains "$PULL" 'SchedulerConfig.model_fields["long_prefill_token_threshold"].default == 0'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-393216}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2072}"'
contains "$RUN" 'LONG_PREFILL_TOKEN_THRESHOLD="${LONG_PREFILL_TOKEN_THRESHOLD:-512}"'
contains "$RUN" 'integer_in_range LONG_PREFILL_TOKEN_THRESHOLD "$LONG_PREFILL_TOKEN_THRESHOLD" 1 512'
contains "$RUN" '(( LONG_PREFILL_TOKEN_THRESHOLD <= MAX_NUM_BATCHED_TOKENS ))'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.986}"'
contains "$RUN" '[ "$GPU_MEMORY_UTILIZATION" = 0.986 ]'
contains "$RUN" 'verify-glm53-flash-exl3-k4-v1.sh'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-mtp-384k-fair-v7"'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--decode-context-parallel-size 2'
contains "$RUN" '--dcp-comm-backend a2a'
contains "$RUN" '--load-format safetensors'
contains "$RUN" '--attention-backend B12X_MLA_SPARSE'
contains "$RUN" '--kv-cache-dtype nvfp4_ds_mla'
contains "$RUN" '-e VLLM_NVFP4_MLA_DYNAMIC_SCALE=0'
contains "$RUN" '-e VLLM_NVFP4_MLA_SCALES_FILE=/opt/glm53/calibration/glm53_nvfp4_mla_outer_scales_mtp_power2_v2.json'
contains "$RUN" '--enable-chunked-prefill'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--long-prefill-token-threshold "$LONG_PREFILL_TOKEN_THRESHOLD"'
contains "$RUN" '--chat-template /opt/glm53/chat_template.multimodal.jinja'
contains "$RUN" '--mm-encoder-attn-backend TORCH_SDPA'
contains "$RUN" '--limit-mm-per-prompt '\''{"image":4,"video":0}'\'''
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'\'''
contains "$RUN" 'ai.peterstorm.inference.prefill-fairness="prefix-cache-plus-long-prefill-token-threshold-$LONG_PREFILL_TOKEN_THRESHOLD"'
contains "$RUN" 'ai.peterstorm.inference.capacity-evidence=nvfp4-kv-625112-tokens-at-v5-boot-baseline'
contains "$RUN" 'ai.peterstorm.inference.kv-cache=nvfp4_ds_mla'
contains "$RUN" '--env-file "$ENVFILE"'
for forbidden in '--language-model-only' '--kv-cache-dtype fp8_ds_mla' '--attention-backend FLASHINFER_MLA_SPARSE_SM120' '--load-format instanttensor' '--no-enable-prefix-caching' 'method":"dflash'; do
  if grep -Fq -- "$forbidden" "$RUN"; then
    echo "FAIL: multimodal NVFP4 v7 contains forbidden text/FP8/DFlash fragment: $forbidden" >&2
    exit 1
  fi
done
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi

contains "$V5_RUN" '--kv-cache-dtype nvfp4_ds_mla'
contains "$V5_RUN" '--no-enable-prefix-caching'
if grep -Fq -- '--long-prefill-token-threshold' "$V5_RUN"; then
  echo 'FAIL: v5 rollback profile must remain unchanged' >&2
  exit 1
fi
contains "$V6_RUN" '--kv-cache-dtype fp8_ds_mla'
contains "$V6_RUN" '--enable-prefix-caching'
contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v7"'
contains "$SWITCH" 'EXPECTED_MODEL="glm-5.3-flash-exl3-k4-vision-mtp-384k-fair-v7"'
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v5'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v6'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v7'

[ "$(jq '[.providers["desktop-vllm"].models[] | select(.id == "glm-5.3-flash-exl3-k4-vision-mtp-384k-fair-v7")] | length' "$PI_MODELS")" -eq 1 ]
jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision-mtp-384k-fair-v7") |
  .input == ["text", "image"] and
  .contextWindow == 393216 and
  .defaultThinkingLevel == "max"
' "$PI_MODELS" >/dev/null

assert_invalid_preflight() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$(env "$@" bash "$RUN" --preflight 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || { echo "FAIL: invalid preflight status=$status: $*" >&2; exit 1; }
  grep -Fq -- "$expected" <<<"$output" || {
    echo "FAIL: invalid preflight did not report: $expected" >&2
    exit 1
  }
}

assert_invalid_preflight 'MAX_MODEL_LEN must be an integer in [1, 393216]' MAX_MODEL_LEN=393217
assert_invalid_preflight 'MAX_NUM_BATCHED_TOKENS must be an integer in [1, 2072]' MAX_NUM_BATCHED_TOKENS=2073
assert_invalid_preflight 'LONG_PREFILL_TOKEN_THRESHOLD must be an integer in [1, 512]' LONG_PREFILL_TOKEN_THRESHOLD=0
assert_invalid_preflight 'LONG_PREFILL_TOKEN_THRESHOLD must be an integer in [1, 512]' LONG_PREFILL_TOKEN_THRESHOLD=513
assert_invalid_preflight 'LONG_PREFILL_TOKEN_THRESHOLD must not exceed MAX_NUM_BATCHED_TOKENS' MAX_NUM_BATCHED_TOKENS=256 LONG_PREFILL_TOKEN_THRESHOLD=512
assert_invalid_preflight 'fixes GPU_MEMORY_UTILIZATION at 0.986' GPU_MEMORY_UTILIZATION=0.985

echo 'PASS: GLM-5.3 v84 multimodal NVFP4/MTP3 v7 is immutable, prefix-cached, fair-prefill bounded, rollback-safe, and unqualified'
