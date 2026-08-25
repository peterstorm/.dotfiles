#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$ROOT/scripts/inference/voice/Dockerfile.indextts25"
BUILD="$ROOT/scripts/inference/voice/build-indextts25-image.sh"
DOWNLOAD="$ROOT/scripts/inference/voice/download-indextts25-models.sh"
RUN="$ROOT/scripts/inference/voice/run-indextts25-no-guide.sh"

contains() {
  grep -Fq -- "$2" "$1" || { echo "missing contract in $1: $2" >&2; exit 1; }
}

for file in "$DOCKERFILE" "$BUILD" "$DOWNLOAD" "$RUN"; do test -f "$file"; done
bash -n "$BUILD" "$DOWNLOAD" "$RUN"
contains "$DOCKERFILE" 'python3.11-bookworm-slim@sha256:4f5d923c9dcea037f57bda425dd209f3ec643da2f0b74227f68d09dab0b3bb36'
contains "$DOCKERFILE" 'INDEXTTS_SOURCE_REV=39207d91c30899cad1e7c1b9eb678c241f678e55'
contains "$DOCKERFILE" 'uv sync --frozen --no-dev'
contains "$DOCKERFILE" 'uv pip check'
contains "$DOCKERFILE" 'UV_PYTHON_INSTALL_DIR=/opt/uv-python'
contains "$DOCKERFILE" 'TextNormalizer(enable_glossary=True).load()'
contains "$DOCKERFILE" '/opt/index-tts/indextts/utils/tagger_cache'
contains "$DOCKERFILE" 'HF_HUB_OFFLINE=1'
contains "$DOCKERFILE" 'NUMBA_CACHE_DIR=/tmp/numba'
contains "$BUILD" '--network none'
contains "$BUILD" '--user 65534:65534'
contains "$BUILD" 'INDEXTTS25_IMAGE_ID='
contains "$DOWNLOAD" 'MODEL_REV="c39ce5ba981572cb187443877ff559dfb246ce63"'
contains "$DOWNLOAD" 'usage=noncommercial-development-only'
contains "$DOWNLOAD" 'amphion/MaskGCT@265c6cef07625665d0c28d2faafb1415562379dc'
contains "$DOWNLOAD" 'ec947271175d8cad75ec37e83aa487e27c97a0f72a303393772da5ffa84bddf2 177183712 hf_cache/semantic_codec_model.safetensors'
contains "$DOWNLOAD" "verify_manifest \"\$STAGING\""
contains "$DOWNLOAD" "verify_manifest \"\$DESTINATION\""
contains "$DOWNLOAD" 'license-accepted-by-user=2026-08-25'
contains "$RUN" '--network none'
contains "$RUN" '--read-only'
contains "$RUN" '--cap-drop all'
contains "$RUN" '--security-opt no-new-privileges'
contains "$RUN" 'INDEXTTS25_EXPECTED_IMAGE_ID'
contains "$RUN" 'usage=noncommercial-development-only'
contains "$RUN" "--mount \"type=bind,src=\$MODEL_ROOT,dst=/models/indextts25,readonly\""
if grep -Eq 'pip install|hf download|curl |wget ' "$RUN"; then
  echo 'runtime script must not download or install anything' >&2
  exit 1
fi

echo INDEXTTS25_VOICE_CONTRACT_PASS
