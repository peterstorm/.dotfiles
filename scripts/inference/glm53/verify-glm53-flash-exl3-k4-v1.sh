#!/usr/bin/env bash
# Re-hash the complete pinned GLM-5.3-Flash EXL3 K4 serving checkpoint (~163.7 GiB).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

MODEL_HOST="${MODEL_HOST:-/models/GLM-5.3-Flash-EXL3-K4-v1}"
REPO="brandonmusic/GLM-5.3-Flash-EXL3-4bpw"
REV="4739eb1bcfd478e8a32da6358908567bc3a9ac51"
MANIFEST_FILE="$SCRIPT_DIR/glm53-flash-exl3-k4-v1.manifest"
EXPECTED="$REPO@$REV"

if [ -L "$MODEL_HOST" ] || [ -L "$MANIFEST_FILE" ]; then
  echo "error: checkpoint and manifest paths must not be symbolic links" >&2
  exit 1
fi

MANIFEST="$(<"$MANIFEST_FILE")"
inference_require_pinned_checkpoint \
  "$MODEL_HOST" "$EXPECTED" "$MANIFEST" \
  "run scripts/inference/glm53/download-glm53-flash-exl3-k4-v1.sh"

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required for the checkpoint metadata contract" >&2
  exit 1
}
jq -e '
  .architectures == ["Glm5NextForConditionalGeneration"] and
  .model_type == "glm5_next" and
  .text_config.max_position_embeddings == 1048576
' "$MODEL_HOST/config.json" >/dev/null || {
  echo "error: checkpoint architecture/context metadata does not match EXL3 v1" >&2
  exit 1
}
jq -e '
  .bits == 4 and
  .codebook == "mcg" and
  .non_routed_dtype_policy == "official_source_native" and
  .quant_method == "exl3" and
  .scope == "glm53_routed_experts_only" and
  .serving_reader_qualified == false and
  .version == "0.0.43"
' "$MODEL_HOST/quantization_config.json" >/dev/null || {
  echo "error: checkpoint EXL3 K4 metadata does not match v1" >&2
  exit 1
}
jq -e '
  .schema == "quant-pipeline.glm53-k4-materialization-receipt.v1" and
  .complete == true and
  .main_and_mtp_complete == true and
  .output_logical_bytes == 175622979576 and
  .output_tensor_count == 150226 and
  .packed_tensor_count == 148608 and
  .source_model_revision == "a6c167b62691b2bac901344b65cb651a70f53e43"
' "$MODEL_HOST/materialization-receipt.json" >/dev/null || {
  echo "error: checkpoint materialization receipt does not match v1" >&2
  exit 1
}
jq -e '
  .metadata.total_size == 175622979576 and
  (.weight_map | length) == 150226
' "$MODEL_HOST/model.safetensors.index.json" >/dev/null || {
  echo "error: checkpoint indexed tensor contract does not match v1" >&2
  exit 1
}
echo "checkpoint metadata contract: PASS"
printf 'Verified %s against all %s serving-manifest records.\n' \
  "$EXPECTED" "$(wc -l <"$MANIFEST_FILE")"
