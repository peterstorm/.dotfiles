#!/usr/bin/env bash
# Re-hash the complete pinned GLM-5.3-Flash-NVFP4 checkpoint (~184.5 GiB).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

MODEL_HOST="${MODEL_HOST:-/models/GLM-5.3-Flash-NVFP4-v1}"
REPO="local-inference-lab/GLM-5.3-Flash-NVFP4"
REV="520de24eabf507659eaef7c70f14fd584527facc"
MANIFEST_FILE="$SCRIPT_DIR/glm53-flash-nvfp4-v1.manifest"
EXPECTED="$REPO@$REV"

if [ -L "$MODEL_HOST" ] || [ -L "$MANIFEST_FILE" ]; then
  echo "error: checkpoint and manifest paths must not be symbolic links" >&2
  exit 1
fi

MANIFEST="$(<"$MANIFEST_FILE")"
inference_require_pinned_checkpoint \
  "$MODEL_HOST" "$EXPECTED" "$MANIFEST" \
  "run scripts/inference/glm53/download-glm53-flash-nvfp4-v1.sh"

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required for the checkpoint metadata contract" >&2
  exit 1
}
jq -e '
  .architectures == ["Glm5NextForConditionalGeneration"] and
  .model_type == "glm5_next" and
  .text_config.max_position_embeddings == 1048576
' "$MODEL_HOST/config.json" >/dev/null || {
  echo "error: checkpoint architecture/context metadata does not match v1" >&2
  exit 1
}
jq -e '
  .quant_method == "modelopt" and
  .quant_algo == "MIXED_PRECISION" and
  ([.quantized_layers[].quant_algo] | unique) == ["MXFP8", "NVFP4"]
' "$MODEL_HOST/hf_quant_config.json" >/dev/null || {
  echo "error: checkpoint ModelOpt mixed-precision metadata does not match v1" >&2
  exit 1
}
jq -e '.metadata.total_size == 198042331512' \
  "$MODEL_HOST/model.safetensors.index.json" >/dev/null || {
  echo "error: checkpoint indexed tensor-byte contract does not match v1" >&2
  exit 1
}
echo "checkpoint metadata contract: PASS"

printf 'Verified %s against all %s manifest records.\n' \
  "$EXPECTED" "$(wc -l <"$MANIFEST_FILE")"
