#!/usr/bin/env bash
# Build and qualify the immutable local Qwen3-TTS voice-audition runtime.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${QWEN3_TTS_IMAGE:-peterstorm/qwen3-tts:0.1.1-022e286-cu130}"
REV="022e286b98fbec7e1e916cb940cdf532cd9f488e"

main() {
  command -v docker >/dev/null 2>&1 || {
    echo 'error: docker is required' >&2
    return 1
  }

  docker build \
    --pull \
    --build-arg "QWEN3_TTS_REV=$REV" \
    --tag "$IMAGE" \
    --file "$SCRIPT_DIR/Dockerfile.qwen3-tts" \
    "$SCRIPT_DIR"

  local image_id source_rev
  image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  source_rev="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [ "$source_rev" = "$REV" ] || {
    echo "error: image source revision mismatch: $source_rev" >&2
    return 1
  }

  docker run --rm --network none --entrypoint python "$IMAGE" -c '
import torch
import transformers
from qwen_tts import Qwen3TTSModel
assert torch.__version__.startswith("2.9.1")
assert torch.version.cuda == "13.0"
assert transformers.__version__ == "4.57.3"
assert Qwen3TTSModel is not None
print("QWEN3_TTS_IMAGE_IMPORT_PASS")
'

  printf 'QWEN3_TTS_IMAGE_READY=%s\n' "$IMAGE"
  printf 'QWEN3_TTS_IMAGE_ID=%s\n' "$image_id"
  echo 'Record the exact image ID in the qualification receipt before production use.'
}

main "$@"
