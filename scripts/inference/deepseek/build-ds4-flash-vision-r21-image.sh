#!/usr/bin/env bash
# Build the immutable Python-only DS4 Vision overlay on Infernal Invocation r21.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONTEXT="$ROOT/scripts/inference/deepseek/ds4-vision-r21-safe"
TAG="${TAG:-peterstorm/vllm:ds4-flash-vision-r21-v1}"
EXPECTED_BASE="sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291"
BASE_REF="voipmonitor/vllm@$EXPECTED_BASE"
EXPECTED_PATCH="800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469"
EXPECTED_BASE_MANIFEST="59a763fb58677c327aa5dd8516fed81ced34da4e61b0ac701e0eb572dd38ff82"
EXPECTED_FINAL_MANIFEST="967c6a451abe7049a66e974148cf8feabbcbbf43511d0c1b32248c8ed0fcf770"
EXPECTED_IMAGE_ID="sha256:f5b3c70a39613bd2459bc186068e8e67720cf69b407a7c91b12a0585bf0ed183"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1788158430}"

require_hash() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(sha256sum "$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    printf 'error: %s hash %s != %s\n' "$path" "$actual" "$expected" >&2
    exit 1
  }
}

require_hash "$EXPECTED_PATCH" "$CONTEXT/ds4-vision-r21.patch"
require_hash "$EXPECTED_BASE_MANIFEST" "$CONTEXT/base-source-sha256.txt"
require_hash "$EXPECTED_FINAL_MANIFEST" "$CONTEXT/final-source-sha256.txt"

docker image inspect "$BASE_REF" >/dev/null

docker buildx build \
  --load \
  --provenance=false \
  --sbom=false \
  --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
  --output "type=docker,rewrite-timestamp=true" \
  --tag "$TAG" \
  "$CONTEXT"

image_id="$(docker image inspect "$TAG" --format '{{.Id}}')"
if [[ -n "$EXPECTED_IMAGE_ID" && "$image_id" != "$EXPECTED_IMAGE_ID" ]]; then
  printf 'error: built image %s != qualified image %s\n' \
    "$image_id" "$EXPECTED_IMAGE_ID" >&2
  exit 1
fi

docker image inspect "$image_id" | jq -e --arg base "$EXPECTED_BASE" --arg patch "$EXPECTED_PATCH" '
  .[0].Config.Labels["local-inference.base.digest"] == $base and
  .[0].Config.Labels["local-inference.vllm.tree"] == "d6cf36ae0dc30d48fd656a3c34a353ec62074922" and
  .[0].Config.Labels["local-inference.ds4.vision.model-revision"] == "86f746b36186f0e567729a5c06a8c918caba82a9" and
  .[0].Config.Labels["org.opencontainers.image.revision"] == $patch
' >/dev/null

docker run --rm --entrypoint python3 "$image_id" \
  /opt/ds4-vision-r21/verify.py --static

printf 'Built DS4 Vision r21 image: %s (%s)\n' "$TAG" "$image_id"
