#!/usr/bin/env bash
# Static contract for the unqualified multimodal GLM-5.3 NVFP4 vLLM/SM120 v2 profile.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/scripts/inference/glm53"
DOWNLOAD="$DIR/download-glm53-flash-nvfp4-v1.sh"
VERIFY="$DIR/verify-glm53-flash-nvfp4-v1.sh"
PULL="$DIR/pull-glm53-flash-vllm-sm120-v2-image.sh"
RUN="$DIR/run-glm53-flash-nvfp4-vllm-sm120-v2.sh"
SWITCH="$DIR/switch-glm53-profile-v2.sh"
MANIFEST="$DIR/glm53-flash-nvfp4-v1.manifest"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-nvfp4-vllm-sm120-v2-runbook-2026-08-27.md"
REV="520de24eabf507659eaef7c70f14fd584527facc"
BASE_DIGEST="sha256:2c6da6c6f16ed15c91e412d896dba13701f25fe1861eaec9ddaa4db34d1d21c4"
IMAGE_DIGEST="sha256:0bd709e80b8ff13ae5de8f7d7f708a499fade3a26970d56afb1be2ff3860fde5"
IMAGE_CONFIG="sha256:136b60b807401679fb529b5fc99ce86c8ec291b38ef01c75801c76696e995be3"
OVERLAY_COMMIT="dc6b4fdd68005ab6ee0b1decfa4ebb8384393d37"
OVERLAY_TREE="b376906774010561e22fa8e234937764f83fd221"
MANIFEST_SHA="98ce8b429c9e8959aa3eccd0a79dc52a6e7901ea0fae1451323d887a1590e9ca"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for script in "$DOWNLOAD" "$VERIFY" "$PULL" "$RUN" "$SWITCH"; do
  [[ -x "$script" ]] || fail "$script is not executable"
  bash -n "$script"
done
jq -e . "$PI_MODELS" >/dev/null || fail "$PI_MODELS is not valid JSON"

[[ "$(sha256sum "$MANIFEST" | cut -d' ' -f1)" = "$MANIFEST_SHA" ]] \
  || fail "checkpoint manifest digest changed"
[[ "$(wc -l <"$MANIFEST")" -eq 53 ]] || fail "checkpoint manifest must contain 53 records"
[[ "$(awk '{sum += $2} END {printf "%.0f", sum}' "$MANIFEST")" = 198098846783 ]] \
  || fail "checkpoint download byte contract changed"
[[ "$(awk '$3 ~ /safetensors$/ {sum += $2} END {printf "%.0f", sum}' "$MANIFEST")" = 198062285544 ]] \
  || fail "safetensors file byte contract changed"
if awk '$3 == "model-00036-of-00036.safetensors" {found=1} END {exit !found}' "$MANIFEST"; then
  fail "manifest includes the unreferenced model-00036 shard"
fi

contains "$DOWNLOAD" "REV=\"$REV\""
contains "$DOWNLOAD" "MANIFEST_SHA256=\"$MANIFEST_SHA\""
contains "$DOWNLOAD" 'allow_patterns=[relative for _, _, relative in records]'
contains "$DOWNLOAD" 'os.replace(temporary, marker)'
contains "$VERIFY" '([.quantized_layers[].quant_algo] | unique) == ["MXFP8", "NVFP4"]'
contains "$VERIFY" '.metadata.total_size == 198042331512'

for identity in "$BASE_DIGEST" "$IMAGE_DIGEST" "$IMAGE_CONFIG" "$OVERLAY_COMMIT" "$OVERLAY_TREE"; do
  contains "$PULL" "$identity"
done
contains "$PULL" '$((${#base_layers[@]} + 2))'
contains "$PULL" '"${overlay_layers[$index]}" = "${base_layers[$index]}"'
contains "$PULL" 'FlashInferMLASparseSM120Impl.supports_dense_mha_prefill is False'
contains "$PULL" '"self.rope_pad = 64" in init_source'
contains "$PULL" '"return_valid_counts=True" in forward_source'
contains "$PULL" 'indexer.count("pool_ids[:, : select_k - 1]") == 2'
contains "$PULL" 'page_sizes = tuple(p for p in page_sizes if p == 64)'

contains "$RUN" 'NAME="glm53-flash-nvfp4-vllm-sm120-v2"'
contains "$RUN" "IMAGE_CONFIG=\"$IMAGE_CONFIG\""
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUN" 'integer_in_range MAX_MODEL_LEN "$MAX_MODEL_LEN" 1 262144'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"'
contains "$RUN" 'integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 8'
contains "$RUN" '--max-num-seqs "$MAX_NUM_SEQS"'
contains "$RUN" '--quantization modelopt_mixed'
contains "$RUN" '--moe-backend marlin'
contains "$RUN" '--kv-cache-dtype fp8_ds_mla'
contains "$RUN" '--mamba-cache-mode none'
contains "$RUN" 'VLLM_ATTENTION_BACKEND=FLASHINFER_MLA_SPARSE_SM120'
contains "$RUN" '--no-enable-flashinfer-autotune'
contains "$RUN" '--limit-mm-per-prompt'
contains "$RUN" '--mm-processor-cache-type shm'
contains "$RUN" '--reasoning-parser glm45'
contains "$RUN" '--tool-call-parser glm47'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" 'inference_prepare_api_key "${VLLM_API_KEY:-}"'
contains "$RUN" 'INFERENCE_GLM_KEYFILE'
contains "$RUN" '-v "$MODEL_HOST:$MODEL_CONTAINER:ro"'
contains "$RUN" 'EXPECTED_POWER_LIMIT_WATTS="450"'
contains "$RUN" '--preflight'
if grep -Fq -- '--language-model-only' "$RUN"; then
  fail "$RUN strips the vision tower from the multimodal v2 profile"
fi
if grep -Eq -- '(^|[[:space:]])--api-key([=[:space:]]|$)' "$RUN"; then
  fail "$RUN exposes the API key in process arguments"
fi
if grep -Fq -- '--speculative-config' "$RUN"; then
  fail "$RUN enables MTP despite the TP2 capacity contract"
fi

status=0
output="$(MAX_NUM_SEQS=9 bash "$RUN" --preflight 2>&1)" || status=$?
[[ "$status" -eq 2 ]] || fail "MAX_NUM_SEQS above 8 did not fail before I/O with status 2"
grep -Fq 'MAX_NUM_SEQS must be an integer in [1, 8]' <<<"$output" \
  || fail "MAX_NUM_SEQS ceiling error is missing"
status=0
output="$(MAX_MODEL_LEN=262145 bash "$RUN" --preflight 2>&1)" || status=$?
[[ "$status" -eq 2 ]] || fail "context above 262144 did not fail before I/O with status 2"
grep -Fq 'MAX_MODEL_LEN must be an integer in [1, 262144]' <<<"$output" \
  || fail "v2 context ceiling error is missing"

contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'HEALTHY + AUTHENTICATED:'
contains "$SWITCH" '--config -'
contains "$SWITCH" 'restore_profiles'
contains "$SWITCH" 'restoring already stopped profiles'
contains "$SWITCH" 'inference_quiesce_failed_container "$TARGET"'
if grep -Eq -- 'curl .*Authorization: Bearer' "$SWITCH"; then
  fail "$SWITCH puts the API key in curl argv"
fi
contains "$CATALOG" 'glm53-flash-nvfp4-vllm-sm120-v2'

jq -e '
  .providers."desktop-vllm" as $provider |
  ($provider.apiKey | contains("~/.config/glm53/api-key")) and
  ($provider.models | any(
    .id == "glm-5.3-flash-nvfp4" and
    .reasoning == true and
    .defaultThinkingLevel == "max" and
    .thinkingLevelMap == {
      "minimal": null,
      "low": "low",
      "medium": null,
      "high": "high",
      "xhigh": null,
      "max": "max"
    } and
    .input == ["text", "image"] and
    .contextWindow == 262144 and
    .compat.supportsReasoningEffort == true and
    .compat.supportsDeveloperRole == false and
    .compat.thinkingFormat == "deepseek"
  ))
' "$PI_MODELS" >/dev/null || fail "Pi GLM profile does not match multimodal v2"

for identity in "$REV" "$BASE_DIGEST" "$IMAGE_DIGEST" "$IMAGE_CONFIG" "$OVERLAY_COMMIT" "$OVERLAY_TREE"; do
  contains "$RUNBOOK" "$identity"
done
contains "$RUNBOOK" '**Prepared, not pulled, not downloaded, not booted, and not qualified.**'
contains "$RUNBOOK" 'max_num_seqs (1024) exceeds available Mamba cache blocks (512)'
contains "$RUNBOOK" 'There is no public end-to-end report for **this exact 184.5-GiB mixed ModelOpt checkpoint'
contains "$RUNBOOK" '524K and native 1M'

printf 'PASS: multimodal GLM-5.3 NVFP4 vLLM/SM120 v2 is pinned, TP2-bounded, and unqualified\n'
