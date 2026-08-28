#!/usr/bin/env bash
# Literal shell fragments below are contract strings, not expressions to expand.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/scripts/inference/glm53/glm53-flash-dflash2-v1.manifest"
TEMPLATE="$ROOT/scripts/inference/glm53/glm53-flash-multimodal-v1.jinja"
DOWNLOAD="$ROOT/scripts/inference/glm53/download-glm53-flash-dflash2-v1.sh"
VERIFY="$ROOT/scripts/inference/glm53/verify-glm53-flash-dflash2-v1.sh"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v3-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v3.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v3.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

for file in "$DOWNLOAD" "$VERIFY" "$PULL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
done
[ "$(sha256sum "$MANIFEST" | cut -d' ' -f1)" = 9979f7d652cd5c971d1db6a5b6093bdd271e711855fcbf22371ecc767d332c9d ]
[ "$(wc -l <"$MANIFEST")" -eq 4 ]
[ "$(awk -F '\t' '{sum+=$2} END {printf "%.0f",sum}' "$MANIFEST")" = 2342175855 ]
[ "$(sha256sum "$TEMPLATE" | cut -d' ' -f1)" = 34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891 ]
contains "$TEMPLATE" '<|begin_of_image|><|image|><|end_of_image|>'
contains "$TEMPLATE" '<|begin_of_video|><|video|><|end_of_video|>'
if grep -Fq "you don't have multi-modal input ability" "$TEMPLATE"; then
  echo 'FAIL: v3 template must not retain the text-only media reminder' >&2
  exit 1
fi

contains "$DOWNLOAD" 'incoai/GLM-5.3-Flash-DFlash2'
contains "$DOWNLOAD" '7d74cdd881ed7e32c31175984a67823127b66cfe'
contains "$DOWNLOAD" 'for attempt in range(1, 9)'
contains "$DOWNLOAD" 'max_workers=2'
contains "$DOWNLOAD" '"block_size": 8'
contains "$DOWNLOAD" '"target_layer_ids": [5, 14, 24, 33, 42]'
contains "$DOWNLOAD" 'os.replace(temporary, marker)'
contains "$VERIFY" 'inference_require_pinned_checkpoint'
contains "$VERIFY" 'license: cc-by-nc-nd-4.0'

contains "$PULL" 'sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692'
contains "$PULL" 'sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$PULL" 'sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578'
contains "$PULL" '(.RootFS.Layers | length) == 113'
contains "$PULL" 'native-pytorch-fallback-when-vllm-flash-attn-layers-absent'
contains "$PULL" 'cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907'
contains "$PULL" 'DFlash2DraftModel'
contains "$PULL" 'rotary.forward_cuda(x, cos, sin)'
contains "$PULL" 'GLM-5.3 v84 DFlash2 + multimodal capability probe: PASS'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-98304}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2072}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.95}"'
contains "$RUN" 'systemctl is-active --quiet comfyui.service'
contains "$RUN" '--served-model-name glm-5.3-flash-exl3-k4-vision'
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
contains "$RUN" '--speculative-config '\''{"method":"dflash","model":"/draft","num_speculative_tokens":7,"draft_tensor_parallel_size":2,"draft_sample_method":"probabilistic","rejection_sample_method":"standard","attention_backend":"TRITON_ATTN","kv_cache_dtype":"auto"}'\'''
contains "$RUN" '--env-file "$ENVFILE"'
if grep -Fq -- '--language-model-only' "$RUN"; then
  echo 'FAIL: multimodal v3 must not disable the vision model' >&2
  exit 1
fi
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v3"'
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'inference_quiesce_failed_container "$TARGET"'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v1'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v2'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v3'
jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision") |
  .input == ["text", "image"] and
  .contextWindow == 98304 and
  .defaultThinkingLevel == "max"
' "$PI_MODELS" >/dev/null

set +e
output="$(GPU_MEMORY_UTILIZATION=0.951 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: GPU_MEMORY_UTILIZATION=0.951 status=$status" >&2; exit 1; }
grep -Fq 'fixes GPU_MEMORY_UTILIZATION at 0.95' <<<"$output"

echo 'PASS: GLM-5.3 v84 vision/DFlash2 v3 is immutable, multimodal-bounded, and rollback-isolated'
