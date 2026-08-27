#!/usr/bin/env bash
# Literal shell fragments below are contract strings, not expressions to expand.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v2-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v2.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v2.sh"
ROLLBACK_RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v1.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

for file in "$PULL" "$RUN" "$SWITCH" "$ROLLBACK_RUN"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
done

contains "$PULL" 'sha256:bb0f2c524f3d55c03df25f62b4c7353fcce6a77468876028da2d6e58530c5f24'
contains "$PULL" 'sha256:8cdac4aa483d6be7bd1a18961e57dbeddefc102f9f786689eece8b8a7ed419aa'
contains "$PULL" 'sha256:711df22b7ccb121fe7838f9dfa23b0ec8235280534be3a08fd55ed58d61d1989'
contains "$PULL" 'b526998ef7644d90569866ef1df82999e26dcbfc'
contains "$PULL" 'e36d2cbcbe235587fb77160bfa39c54b7c260fa361bba67e294a5eff4890a7e3'
contains "$PULL" 'local-token-split-zero-row-and-kpool-live-write-count'
contains "$PULL" '36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8'
contains "$PULL" 'num_nextn_predict_layers=1'
contains "$PULL" 'GLM-5.3 EXL3 K4 TP2 vLLM capability probe: PASS'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-499968}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.988}"'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--decode-context-parallel-size 1'
contains "$RUN" '--dcp-comm-backend a2a'
contains "$RUN" '--load-format safetensors'
contains "$RUN" '--quantization exl3'
contains "$RUN" '--moe-backend b12x'
contains "$RUN" '--attention-backend B12X_MLA_SPARSE'
contains "$RUN" '--kv-cache-dtype nvfp4_ds_mla'
contains "$RUN" '--enable-chunked-prefill'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--disable-custom-all-reduce'
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'\'''
contains "$RUN" '-e VLLM_USE_B12X_DCP_A2A=1'
contains "$RUN" '-e NCCL_P2P_LEVEL=4'
contains "$RUN" '--reasoning-parser glm45'
contains "$RUN" '--tool-call-parser glm47'
contains "$RUN" '--env-file "$ENVFILE"'
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi
if grep -Fq -- '--enforce-eager' "$RUN" || grep -Fq -- '--no-enable-prefix-caching' "$RUN"; then
  echo 'FAIL: v2 must retain upstream CUDA graphs and prefix caching' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v2"'
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v1'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v2'
jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4") |
  .input == ["text"] and .contextWindow == 499968 and .defaultThinkingLevel == "max"
' "$PI_MODELS" >/dev/null

set +e
output="$(MAX_NUM_SEQS=5 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: MAX_NUM_SEQS=5 status=$status" >&2; exit 1; }
grep -Fq 'MAX_NUM_SEQS must be an integer in [1, 4]' <<<"$output"

echo 'PASS: GLM-5.3 EXL3 K4 v37 TP2/MTP3 v2 matches the pinned upstream daily-driver envelope'
