#!/usr/bin/env bash
# Literal shell fragments below are contract strings, not expressions to expand.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD="$ROOT/scripts/inference/glm53/download-glm53-flash-exl3-k4-v1.sh"
VERIFY="$ROOT/scripts/inference/glm53/verify-glm53-flash-exl3-k4-v1.sh"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v1-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v1.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v1.sh"
MANIFEST="$ROOT/scripts/inference/glm53/glm53-flash-exl3-k4-v1.manifest"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

[ "$(sha256sum "$MANIFEST" | cut -d' ' -f1)" = 96bb2e8ebdc287233c142f05465ac180c34c25e47a3b8ef338882faced3f52b7 ]
[ "$(wc -l <"$MANIFEST")" -eq 135 ]
[ "$(awk -F '\t' '{sum+=$2} END {printf "%.0f",sum}' "$MANIFEST")" = 175715798014 ]
awk -F '\t' 'length($1) != 64 || $2 !~ /^[0-9]+$/ || $3 == "" {exit 1}' "$MANIFEST"

for file in "$DOWNLOAD" "$VERIFY" "$PULL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
done

contains "$DOWNLOAD" 'brandonmusic/GLM-5.3-Flash-EXL3-4bpw'
contains "$DOWNLOAD" '4739eb1bcfd478e8a32da6358908567bc3a9ac51'
contains "$DOWNLOAD" 'allow_patterns=[relative for _, _, relative in records]'
contains "$DOWNLOAD" 'quant.get("serving_reader_qualified") is not False'
contains "$DOWNLOAD" 'os.replace(temporary, marker)'
contains "$VERIFY" 'inference_require_pinned_checkpoint'
contains "$VERIFY" '.output_logical_bytes == 175622979576'

contains "$PULL" 'sha256:a6962d4a45474e9b50e26d888d739076c5fbe51e5e531c2d11ead3d74285f484'
contains "$PULL" 'sha256:19a51d921523dd0c21afbf99bb49a00fc2d3feb6f565b1d3474ed0120372d847'
contains "$PULL" 'local-inference.glm53.vllm-overlay'
contains "$PULL" 'df684ff47dcbf088b41311494fd20347a702e56a'
contains "$PULL" 'GLM-5.3 EXL3 K4 TP2 vLLM capability probe: PASS'
contains "$PULL" 'source labels are pinned but the GLM overlay commits are not publicly reconstructible'

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"'
contains "$RUN" 'integer_in_range MAX_NUM_SEQS "$MAX_NUM_SEQS" 1 8'
contains "$RUN" '--entrypoint /opt/venv/bin/python'
contains "$RUN" '-m vllm.entrypoints.openai.api_server'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--quantization exl3'
contains "$RUN" '--attention-backend B12X_MLA_SPARSE'
contains "$RUN" '--kv-cache-dtype nvfp4_ds_mla'
contains "$RUN" '--language-model-only'
contains "$RUN" '--mamba-cache-mode none'
contains "$RUN" '--enforce-eager'
contains "$RUN" '--no-enable-prefix-caching'
contains "$RUN" '--reasoning-parser glm45'
contains "$RUN" '--tool-call-parser glm47'
contains "$RUN" '--env-file "$ENVFILE"'
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'authenticated_models_status'
contains "$SWITCH" 'inference_quiesce_failed_container "$TARGET"'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v1'
jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4") |
  .input == ["text"] and .contextWindow == 131072 and .defaultThinkingLevel == "max"
' "$PI_MODELS" >/dev/null

set +e
output="$(MAX_NUM_SEQS=9 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: MAX_NUM_SEQS=9 status=$status" >&2; exit 1; }
grep -Fq 'MAX_NUM_SEQS must be an integer in [1, 8]' <<<"$output"

echo 'PASS: GLM-5.3 EXL3 K4 vLLM SM120 v1 is pinned, TP2-bounded, and experimental'
