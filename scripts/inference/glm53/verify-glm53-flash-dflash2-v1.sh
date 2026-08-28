#!/usr/bin/env bash
# Re-hash and validate the pinned GLM-5.3 DFlash2 draft checkpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

MODEL_HOST="${MODEL_HOST:-/models/GLM-5.3-Flash-DFlash2-v1}"
REPO="incoai/GLM-5.3-Flash-DFlash2"
REV="7d74cdd881ed7e32c31175984a67823127b66cfe"
MANIFEST_FILE="$SCRIPT_DIR/glm53-flash-dflash2-v1.manifest"
EXPECTED="$REPO@$REV"

if [ -L "$MODEL_HOST" ] || [ -L "$MANIFEST_FILE" ]; then
  echo "error: draft checkpoint and manifest paths must not be symbolic links" >&2
  exit 1
fi
MANIFEST="$(<"$MANIFEST_FILE")"
inference_require_pinned_checkpoint \
  "$MODEL_HOST" "$EXPECTED" "$MANIFEST" \
  "run scripts/inference/glm53/download-glm53-flash-dflash2-v1.sh"

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required for the DFlash2 metadata contract" >&2
  exit 1
}
jq -e '
  .architectures == ["DFlash2DraftModel"] and
  .dtype == "bfloat16" and
  .num_hidden_layers == 5 and
  .sliding_window == 2048 and
  .vocab_size == 154880 and
  .dflash_config == {
    "block_size": 8,
    "conv_group_size": 16,
    "conv_kernel_size": 2,
    "mask_token_id": 154856,
    "selector_rank": 256,
    "selector_top_k": 16,
    "target_layer_ids": [5, 14, 24, 33, 42]
  }
' "$MODEL_HOST/config.json" >/dev/null || {
  echo "error: DFlash2 architecture/block contract differs" >&2
  exit 1
}
grep -Fq 'license: cc-by-nc-nd-4.0' "$MODEL_HOST/README.md" || {
  echo "error: DFlash2 CC-BY-NC-ND-4.0 declaration is absent" >&2
  exit 1
}
printf 'Verified %s against all %s manifest records.\n' \
  "$EXPECTED" "$(wc -l <"$MANIFEST_FILE")"
