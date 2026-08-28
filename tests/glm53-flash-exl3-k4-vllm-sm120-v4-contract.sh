#!/usr/bin/env bash
# Literal shell fragments below are contract strings, not expressions to expand.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v3-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v4.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v4.sh"
V3_RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v3.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

for file in "$PULL" "$RUN" "$SWITCH" "$V3_RUN"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
done
contains "$PULL" 'sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$PULL" 'sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578'
contains "$PULL" 'native-pytorch-fallback-when-vllm-flash-attn-layers-absent'
contains "$PULL" '"TORCH_SDPA" in AttentionBackendEnum.__members__'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-98304}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2072}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.986}"'
contains "$RUN" '[ "$GPU_MEMORY_UTILIZATION" = 0.986 ]'
contains "$RUN" 'verify-glm53-flash-exl3-k4-v1.sh'
contains "$RUN" '--served-model-name glm-5.3-flash-exl3-k4-vision-mtp'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--decode-context-parallel-size 2'
contains "$RUN" '--dcp-comm-backend a2a'
contains "$RUN" '--attention-backend B12X_MLA_SPARSE'
contains "$RUN" '--kv-cache-dtype nvfp4_ds_mla'
contains "$RUN" '--no-enable-prefix-caching'
contains "$RUN" '--chat-template /opt/glm53/chat_template.multimodal.jinja'
contains "$RUN" '--mm-encoder-attn-backend TORCH_SDPA'
contains "$RUN" '--limit-mm-per-prompt '\''{"image":4,"video":0}'\'''
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'\'''
contains "$RUN" 'ai.peterstorm.inference.speculation=mtp3'
contains "$RUN" '--env-file "$ENVFILE"'
for forbidden in DFLASH_HOST DFLASH_CONTAINER '/draft' 'method":"dflash' 'verify-glm53-flash-dflash2-v1.sh' '--language-model-only' '--enforce-eager'; do
  if grep -Fq -- "$forbidden" "$RUN"; then
    echo "FAIL: MTP v4 contains forbidden DFlash/toggle fragment: $forbidden" >&2
    exit 1
  fi
done
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi

contains "$V3_RUN" '"method":"dflash"'
contains "$V3_RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.95}"'
contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v4"'
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'inference_quiesce_failed_container "$TARGET"'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v3'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v4'
jq -e '
  [.providers["desktop-vllm"].models[] | select(.id == "glm-5.3-flash-exl3-k4-vision-mtp")] |
  length == 0
' "$PI_MODELS" >/dev/null

set +e
output="$(GPU_MEMORY_UTILIZATION=0.985 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: GPU_MEMORY_UTILIZATION=0.985 status=$status" >&2; exit 1; }
grep -Fq 'fixes GPU_MEMORY_UTILIZATION at 0.986' <<<"$output"

echo 'PASS: GLM-5.3 v84 vision/MTP3 v4 is immutable, draft-free, and rollback-isolated'
