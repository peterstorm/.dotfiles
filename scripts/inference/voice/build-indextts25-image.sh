#!/usr/bin/env bash
# Build and import-qualify the immutable IndexTTS-2.5 no-guide runtime.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${INDEXTTS25_IMAGE:-peterstorm/indextts25:2.5.0-39207d9-cu128}"
REV="39207d91c30899cad1e7c1b9eb678c241f678e55"

main() {
  command -v docker >/dev/null 2>&1 || {
    echo 'error: docker is required' >&2
    return 1
  }

  docker build \
    --pull \
    --build-arg "INDEXTTS_SOURCE_REV=$REV" \
    --tag "$IMAGE" \
    --file "$SCRIPT_DIR/Dockerfile.indextts25" \
    "$SCRIPT_DIR"

  local image_id source_rev
  image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  source_rev="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [[ "$source_rev" == "$REV" ]] || {
    echo "error: image source revision mismatch: $source_rev" >&2
    return 1
  }

  docker run --rm --network none --user 65534:65534 --entrypoint /opt/index-tts/.venv/bin/python "$image_id" -c '
import torch
from indextts.infer_v2_5 import IndexTTS2
assert torch.__version__.startswith("2.8.")
assert torch.version.cuda == "12.8"
assert IndexTTS2 is not None
print("INDEXTTS25_IMAGE_IMPORT_PASS")
'

  printf 'INDEXTTS25_IMAGE_READY=%s\n' "$IMAGE"
  printf 'INDEXTTS25_IMAGE_ID=%s\n' "$image_id"
}

main "$@"
