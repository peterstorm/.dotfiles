#!/usr/bin/env bash
# Build pinned offline identity-audition runtimes without starting GPU work.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
VOX_IMAGE="${VOXCPM2_IMAGE:-peterstorm/voxcpm2:f5a1c6a-cu130}"
BREEZE_IMAGE="${BREEZE_TTS2_IMAGE:-peterstorm/breeze-tts2:ca632ce-cu130}"

build_image() {
  local dockerfile="$1" image="$2" revision="$3"
  docker build \
    --file "$dockerfile" \
    --tag "$image" \
    "$ROOT"
  local image_id image_revision
  image_id="$(docker image inspect "$image" --format '{{.Id}}')"
  image_revision="$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [ "$image_revision" = "$revision" ] || {
    echo "error: image revision mismatch for $image: $image_revision" >&2
    return 1
  }
  printf 'VOICE_IDENTITY_IMAGE_READY image=%s image_id=%s revision=%s\n' "$image" "$image_id" "$image_revision"
}

main() {
  case "${1:-all}" in
    all)
      build_image "$ROOT/scripts/inference/voice/Dockerfile.voxcpm2" "$VOX_IMAGE" \
        f5a1c6a6b901bc732e20f0d59a369f6829ad717a
      build_image "$ROOT/scripts/inference/voice/Dockerfile.breeze-tts2" "$BREEZE_IMAGE" \
        ca632ce6c4d05f7985da4eab29b1a5d445b43f7b
      ;;
    voxcpm2)
      build_image "$ROOT/scripts/inference/voice/Dockerfile.voxcpm2" "$VOX_IMAGE" \
        f5a1c6a6b901bc732e20f0d59a369f6829ad717a
      ;;
    breeze-tts2)
      build_image "$ROOT/scripts/inference/voice/Dockerfile.breeze-tts2" "$BREEZE_IMAGE" \
        ca632ce6c4d05f7985da4eab29b1a5d445b43f7b
      ;;
    *)
      echo "usage: $0 [all|voxcpm2|breeze-tts2]" >&2
      return 2
      ;;
  esac
}

main "$@"
