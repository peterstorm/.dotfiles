#!/usr/bin/env bash
# Re-hash and validate the complete pinned Qwen3.8-Flash-Next FP8 checkpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

MODEL_HOST="${MODEL_HOST:-/models/Qwen3.8-Flash-Next-FP8-v1}"
REPO="Qwen/Qwen3.8-Flash-Next-FP8"
REV="970c569adaca6b35532111fd6b27351b2baefe50"
MANIFEST_FILE="$SCRIPT_DIR/qwen38-flash-next-fp8-v1.manifest"
EXPECTED="$REPO@$REV"

if [ -L "$MODEL_HOST" ] || [ -L "$MANIFEST_FILE" ]; then
  echo "error: checkpoint and manifest paths must not be symbolic links" >&2
  exit 1
fi

MANIFEST="$(<"$MANIFEST_FILE")"
inference_require_pinned_checkpoint \
  "$MODEL_HOST" "$EXPECTED" "$MANIFEST" \
  "run scripts/inference/qwen38/download-qwen38-flash-next-fp8-v1.sh"

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required for the checkpoint metadata contract" >&2
  exit 1
}
jq -e '
  .architectures == ["Qwen4ExpForConditionalGeneration"] and
  .model_type == "qwen4_exp" and
  .text_config.model_type == "qwen4_exp_text" and
  .text_config.max_position_embeddings == 262144 and
  .text_config.num_hidden_layers == 48 and
  .text_config.num_experts == 512 and
  .text_config.num_experts_per_tok == 10 and
  .text_config.ngram_size == 3 and
  .text_config.ngram_vocab_size_base == 20000000 and
  .text_config.split_ngram_parts == 128 and
  .text_config.heads_per_ngram == 8 and
  .text_config.ple_embed_dim == 2560 and
  .text_config.ple_layer_ids == [2] and
  .text_config.mtp_num_hidden_layers == 1 and
  .quantization_config.quant_method == "fp8" and
  .quantization_config.activation_scheme == "dynamic" and
  .quantization_config.weight_block_size == [128, 128]
' "$MODEL_HOST/config.json" >/dev/null || {
  echo "error: checkpoint architecture, PLE, MTP, context, or FP8 metadata differs" >&2
  exit 1
}
jq -e '
  .metadata.total_size == 185502232570 and
  (.weight_map | length) == 152089 and
  ([.weight_map | to_entries[] |
    select(.key | startswith("model.language_model.layers.1.ple.ple_embedding.ngram_embedding.shard_")) |
    select(.key | endswith(".weight"))] | length) == 128
' "$MODEL_HOST/model.safetensors.index.json" >/dev/null || {
  echo "error: checkpoint tensor or 128-way N-gram sharding contract differs" >&2
  exit 1
}
IFS= read -r license_identity < "$MODEL_HOST/LICENSE" || {
  echo "error: checkpoint license identity is unreadable" >&2
  exit 1
}
[ "${license_identity%$'\r'}" = 'Qwen Community License 1.0' ] || {
  echo "error: checkpoint license identity differs" >&2
  exit 1
}
echo "checkpoint metadata contract: PASS"
printf 'Verified %s against all %s serving-manifest records.\n' \
  "$EXPECTED" "$(wc -l <"$MANIFEST_FILE")"
