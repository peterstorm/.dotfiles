#!/usr/bin/env bash
# Static contract for the unqualified multimodal GLM-5.3 EXL3 K4 v84 FP8-DS-MLA/MTP3 v8 profile.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v8-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v8.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v8.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-exl3-k4-vllm-sm120-v8-runbook-2026-08-29.md"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

for file in "$PULL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done

contains "$PULL" 'sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$PULL" 'sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578'
contains "$PULL" 'sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692'
contains "$PULL" 'r19-sm120-tp2-ep2-dcp2-v84-language-only'
contains "$PULL" 'Glm5NextForConditionalGeneration'
contains "$PULL" 'multimodal_chat_template.jinja'
contains "$PULL" '34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891'
contains "$PULL" '"TORCH_SDPA" in AttentionBackendEnum.__members__'
contains "$PULL" '"FLASHINFER_MLA_SPARSE_SM120" in AttentionBackendEnum.__members__'
contains "$PULL" 'profile_capabilities=multimodal,fp8_ds_mla,flashinfer_mla_sparse_sm120,prefix_cache,mtp3'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-359000}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.986}"'
contains "$RUN" '[ "$GPU_MEMORY_UTILIZATION" = 0.986 ]'
contains "$RUN" '--restart no'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v8"'
contains "$RUN" '--shm-size 32g'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--decode-context-parallel-size 2'
contains "$RUN" '--dcp-comm-backend a2a'
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--load-format safetensors'
contains "$RUN" '--moe-backend b12x'
contains "$RUN" '--max-model-len "$MAX_MODEL_LEN"'
contains "$RUN" '--enable-chunked-prefill'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--enable-prompt-tokens-details'
contains "$RUN" '--generation-config "$MODEL_CONTAINER"'
contains "$RUN" '--reasoning-parser glm45'
contains "$RUN" '--tool-call-parser glm47'
contains "$RUN" '--enable-auto-tool-choice'
contains "$RUN" '--disable-custom-all-reduce'
contains "$RUN" '--chat-template /opt/glm53/chat_template.multimodal.jinja'
contains "$RUN" '--mm-encoder-attn-backend TORCH_SDPA'
contains "$RUN" '--limit-mm-per-prompt '\''{"image":4,"video":0}'\'''
contains "$RUN" '--attention-backend FLASHINFER_MLA_SPARSE_SM120'
contains "$RUN" '--kv-cache-dtype fp8_ds_mla'
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'\'''
contains "$RUN" '-e VLLM_B12X_GLM_NOPE_NVFP4=0'
contains "$RUN" '-e VLLM_EXL3_PREFILL_BLOCK_M=128'
contains "$RUN" '-e VLLM_EXL3_PREFILL_TRELLIS=1'
contains "$RUN" '-e B12X_GL53_ROUTE128_WIDE=1'
contains "$RUN" '-e B12X_GL53_ROUTE128_HYBRID_TAIL=1'
contains "$RUN" '-e VLLM_USE_B12X_DCP_A2A=1'
contains "$RUN" '-e VLLM_ENABLE_PCIE_ALLREDUCE=1'
contains "$RUN" '-e VLLM_PCIE_ALLREDUCE_BACKEND=cpp'
contains "$RUN" '-e NCCL_P2P_LEVEL=4'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" 'ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v8-boot'
for forbidden in '--language-model-only' '--load-format instanttensor' '--kv-cache-dtype nvfp4_ds_mla' '--attention-backend B12X_MLA_SPARSE' '--no-enable-prefix-caching' 'method":"dflash'; do
  if grep -Fq -- "$forbidden" "$RUN"; then
    echo "FAIL: multimodal FP8/MTP3 v8 contains forbidden profile fragment: $forbidden" >&2
    exit 1
  fi
done
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v8"'
contains "$SWITCH" 'EXPECTED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v8"'
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" 'IDLE GATE: no running or waiting requests across three samples'
contains "$SWITCH" 'vllm:num_requests_(running|waiting)'
contains "$SWITCH" 'Available KV cache memory:'
contains "$SWITCH" 'GPU KV cache size:'
contains "$SWITCH" 'KV CACHE BOOT RECEIPT'
contains "$SWITCH" 'exl3-k4-vllm-sm120-v8-kv-capacity.txt'
contains "$SWITCH" 'if ! wait_for_target || ! report_kv_capacity || ! promote_restart_policy; then'
contains "$SWITCH" 'docker update --restart=unless-stopped "$TARGET"'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v8'
contains "$RUNBOOK" 'Available FP8 KV memory |'
contains "$RUNBOOK" 'Engine KV token capacity |'
contains "$RUNBOOK" 'vision: enabled (no --language-model-only)'
contains "$RUNBOOK" 'MTP3 is mandatory and contract-tested'
contains "$RUNBOOK" '3.79 GiB/GPU'
contains "$RUNBOOK" '749,676 tokens'
contains "$RUNBOOK" '2.09x'
contains "$RUNBOOK" 'returned exactly `red`'

jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v8") |
  .input == ["text", "image"] and
  .contextWindow == 359000 and
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

assert_invalid_preflight 'MAX_MODEL_LEN must be an integer in [1, 359000]' MAX_MODEL_LEN=359001
assert_invalid_preflight 'MAX_NUM_BATCHED_TOKENS must be an integer in [1, 2048]' MAX_NUM_BATCHED_TOKENS=2049
assert_invalid_preflight 'MAX_NUM_SEQS must be an integer in [1, 4]' MAX_NUM_SEQS=5
assert_invalid_preflight 'fixes GPU_MEMORY_UTILIZATION at 0.986' GPU_MEMORY_UTILIZATION=0.987

echo 'PASS: GLM-5.3 v84 multimodal FP8-DS-MLA/MTP3 359K v8 is immutable, vision-enabled, capacity-receipted, rollback-safe, and basic-smoke-qualified'
