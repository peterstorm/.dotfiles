#!/usr/bin/env bash
# Static contract for the GLM-5.3 MTP3 + prefix-state-safe multimodal FP8-DS-MLA v8 profile.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v8-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v8.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v8.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-exl3-k4-vllm-sm120-v8-runbook-2026-08-29.md"
OVERLAY="$ROOT/scripts/inference/glm53/glm53-mtp-prefix-safety"
DOCKERFILE="$OVERLAY/Dockerfile"
PATCH="$OVERLAY/glm53-mtp-prefix-state-safety.patch"
EXACT_TOPK_PATCH="$OVERLAY/glm53-exact-sparse-topk.patch"

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
contains "$PULL" 'sha256:ab8bf15ab9bd35c01dd1dac3d1a7474e3922f507bb3159695059ac9bbc1eed8d'
contains "$PULL" 'sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692'
contains "$PULL" 'UPSTREAM_PR_HEAD="9a198c0f8452d0eb251509f02753853903d9f17f"'
contains "$PULL" 'vllm-project/vllm#50021@$UPSTREAM_PR_HEAD'
contains "$PULL" 'a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85'
contains "$PULL" 'cpu-proven-complete-in-range'
contains "$PULL" 'does not retain the exact base rootfs prefix'
[ "$(sha256sum "$PATCH" | cut -d' ' -f1)" = 'a8e288ec067fed7e2e38762ca71e6034982dc4d40dc02ceec5caa1dc319ace85' ] || {
  echo 'FAIL: GLM state-safety patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$EXACT_TOPK_PATCH" | cut -d' ' -f1)" = '00254654846b80fc0ff44019ca0641586023b46993bac4af3e579cf8522a3041' ] || {
  echo 'FAIL: GLM exact sparse-top-k patch digest differs' >&2
  exit 1
}
contains "$DOCKERFILE" 'FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$DOCKERFILE" 'overlay-upstream-pr="vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f"'
contains "$DOCKERFILE" 'exact-topk-issue="vllm-project/vllm#51782"'
contains "$DOCKERFILE" 'exact-topk-patch-sha256="00254654846b80fc0ff44019ca0641586023b46993bac4af3e579cf8522a3041"'
contains "$DOCKERFILE" 'patch --batch --fuzz=0'
contains "$PATCH" '_build_mixed_token_indices_cpu'
contains "$PATCH" 'idx_in_row = (i_t >= 0) & (i_t < stride_indices_seq)'
contains "$EXACT_TOPK_PATCH" 'def _exact_sparse_attn_topk('
contains "$EXACT_TOPK_PATCH" 'deterministic_keys = (score_keys << 32)'
contains "$EXACT_TOPK_PATCH" 'torch.topk('
contains "$EXACT_TOPK_PATCH" 'deterministic_keys, selected_width, dim=1, sorted=True'
contains "$EXACT_TOPK_PATCH" '_exact_sparse_attn_topk(logits, seq_lens, topk_dst, work_k)'
if grep '^+' "$EXACT_TOPK_PATCH" | grep -Fq 'torch.ops._C.persistent_topk('; then
  echo 'FAIL: exact sparse-top-k patch adds a persistent_topk call' >&2
  exit 1
fi
contains "$PULL" 'vllm-project/vllm#51782'
contains "$PULL" 'columns, visible, topk = 806_736, 4_096, 512'
contains "$PULL" '_exact_sparse_attn_topk(logits, seq_lens, topk_indices, topk)'
contains "$PULL" 'tied_indices[0], torch.tensor([0, 1, 2, 3, -1]'
contains "$PULL" 'profile_capabilities=multimodal,fp8_ds_mla,flashinfer_mla_sparse_sm120,prefix_cache,mtp3,state_bounds,exact_sparse_topk'
contains "$PULL" 'Glm5NextForConditionalGeneration'
contains "$PULL" 'chat_template.multimodal.jinja'
contains "$PULL" '34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891'
contains "$PULL" '"TORCH_SDPA" in AttentionBackendEnum.__members__'
contains "$PULL" '"FLASHINFER_MLA_SPARSE_SM120" in AttentionBackendEnum.__members__'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-359000}"'
contains "$RUN" 'MODEL_HOST="${MODEL_HOST:-$HOME/models/GLM-5.3-Flash-EXL3-K4-v1}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.986}"'
contains "$RUN" '[ "$GPU_MEMORY_UTILIZATION" = 0.986 ]'
contains "$RUN" '--restart no'
contains "$RUN" 'IMAGE="sha256:ab8bf15ab9bd35c01dd1dac3d1a7474e3922f507bb3159695059ac9bbc1eed8d"'
contains "$RUN" 'ai.peterstorm.inference.prefix-cache=mandatory'
contains "$RUN" 'ai.peterstorm.inference.state-safety=pr50021-plus-cpu-mixed-partition'
contains "$RUN" 'ai.peterstorm.inference.exact-sparse-topk=vllm-51782-torch-topk'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v8"'
contains "$RUN" '--shm-size 32g'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--decode-context-parallel-size 1'
contains "$RUN" '--dtype bfloat16'
contains "$RUN" '--load-format safetensors'
contains "$RUN" '--moe-backend b12x'
contains "$RUN" '--max-model-len "$MAX_MODEL_LEN"'
contains "$RUN" '--enable-chunked-prefill'
contains "$RUN" '--enforce-eager'
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
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"greedy"}'\'''
contains "$RUN" '-e VLLM_B12X_GLM_NOPE_NVFP4=0'
contains "$RUN" '-e VLLM_EXL3_PREFILL_BLOCK_M=128'
contains "$RUN" '-e VLLM_EXL3_PREFILL_TRELLIS=1'
contains "$RUN" '-e B12X_GL53_ROUTE128_WIDE=1'
contains "$RUN" '-e B12X_GL53_ROUTE128_HYBRID_TAIL=1'
contains "$RUN" '-e VLLM_ENABLE_PCIE_ALLREDUCE=1'
contains "$RUN" '-e VLLM_PCIE_ALLREDUCE_BACKEND=cpp'
contains "$RUN" '-e NCCL_P2P_LEVEL=4'
contains "$RUN" '-e NCCL_ALGO=Ring'
contains "$RUN" '-e NCCL_PROTO=Simple'
contains "$RUN" '-e CUDA_DEVICE_MAX_CONNECTIONS=1'
contains "$RUN" '-e CUBLAS_WORKSPACE_CONFIG=:4096:8'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" 'ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v8-boot'
for forbidden in '--decode-context-parallel-size 2' '--dcp-comm-backend a2a' '-e VLLM_USE_B12X_DCP_A2A=1' '--language-model-only' '--load-format instanttensor' '--kv-cache-dtype nvfp4_ds_mla' '--attention-backend B12X_MLA_SPARSE' '--no-enable-prefix-caching' 'method":"dflash'; do
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

echo 'PASS: GLM-5.3 MTP3 + prefix-state-safe + exact-sparse-top-k multimodal FP8-DS-MLA 359K v8 is immutable, bounded, vision-enabled, capacity-receipted, and rollback-safe'
